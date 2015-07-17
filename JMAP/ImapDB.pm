#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::ImapDB;
use base qw(JMAP::DB);

use DBI;
use Date::Parse;
use JSON::XS qw(encode_json decode_json);
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Encode;
use Encode::MIME::Header;
use Digest::SHA qw(sha1_hex);
use AnyEvent;
use AnyEvent::Socket;
use Data::Dumper;
use JMAP::Sync::Gmail;
use JMAP::Sync::ICloud;
use JMAP::Sync::Fastmail;

our $TAG = 1;

# special use or name magic
my %ROLE_MAP = (
  'inbox' => 'inbox',
  'drafts' => 'drafts',
  'junk' => 'spam',
  'deleted messages' => 'trash',
  'archive' => 'archive',
  'sent messages' => 'sent',
  'sent items' => 'sent',
  'trash' => 'trash',
  '\\inbox' => 'inbox',
  '\\trash' => 'trash',
  '\\sent' => 'sent',
  '\\junk' => 'junk',
  '\\archive' => 'archive',
  '\\drafts' => 'drafts',
);

sub setuser {
  my $Self = shift;
  my ($hostname, $username, $password) = @_;
  $Self->begin();
  my $data = $Self->dbh->selectrow_arrayref("SELECT hostname, username, password FROM iserver");
  if ($data and $data->[0]) {
    $Self->dmaybeupdate('iserver', {hostname => $hostname, username => $username, password => $password}, {hostname => $data->[0]});
  }
  else {
    $Self->dinsert('iserver', {
      hostname => $hostname,
      username => $username,
      password => $password,
    });
  }
  my $user = $Self->dbh->selectrow_arrayref("SELECT email FROM account");
  if ($user and $user->[0]) {
    $Self->dmaybeupdate('account', {email => $username}, {email => $username});
  }
  else {
    $Self->dinsert('account', {
      email => $username,
      jdeletedmodseq => 0,
      jhighestmodseq => 1,
    });
  }
  $Self->commit();
}

sub access_token {
  my $Self = shift;

  my ($hostname, $username, $password) = $Self->dbh->selectrow_array("SELECT hostname, username, password FROM iserver");

  return [$hostname, $username, $password];
}

# synchronous backend for now
sub backend_cmd {
  my $Self = shift;
  my $cmd = shift;
  my @args = @_;

  use Carp;
  Carp::confess("in transaction") if $Self->in_transaction();

  unless ($Self->{backend}) {
    my $auth = $Self->access_token();
    my $config = { hostname => $auth->[0], username => $auth->[1], password => $auth->[2] };
    my $backend;
    if ($config->{hostname} eq 'gmail') {
      $backend = JMAP::Sync::Gmail->new($config) || die "failed to setup $auth->[1]";
    } elsif ($config->{hostname} eq 'imap.mail.me.com') {
      $backend = JMAP::Sync::ICloud->new($config) || die "failed to setup $auth->[1]";
    } elsif ($config->{hostname} eq 'mail.messagingengine.com') {
      $backend = JMAP::Sync::Fastmail->new($config) || die "failed to setup $auth->[1]";
    } else {
      die "UNKNOWN ID $config->{username} ($config->{hostname})";
    }
    $Self->{backend} = $backend;
  }

  die "No such command $cmd" unless $Self->{backend}->can($cmd);
  return $Self->{backend}->$cmd(@args);
}

# synchronise list from IMAP server to local folder cache
# call in transaction
sub sync_folders {
  my $Self = shift;

  my $folders = $Self->backend_cmd('folders', []);

  $Self->begin();
  my $dbh = $Self->dbh();

  my $ifolders = $dbh->selectall_arrayref("SELECT ifolderid, sep, uidvalidity, imapname, label FROM ifolders");
  my %ibylabel = map { $_->[4] => $_ } @$ifolders;
  my %seen;

  my %getstatus;
  foreach my $name (sort keys %$folders) {
    my $sep = $folders->{$name}[0];
    my $role = $ROLE_MAP{lc $folders->{$name}[1]};
    my $label = $role || $folders->{$name}[1];
    my $id = $ibylabel{$label}[0];
    if ($id) {
      $Self->dmaybeupdate('ifolders', {sep => $sep, imapname => $name}, {ifolderid => $id});
    }
    else {
      $id = $Self->dinsert('ifolders', {sep => $sep, imapname => $name, label => $label});
    }
    $seen{$id} = 1;
    unless ($ibylabel{$label}[2]) {
      # no uidvalidity, we need to get status for this one
      $getstatus{$name} = $id;
    }
  }

  foreach my $folder (@$ifolders) {
    my $id = $folder->[0];
    next if $seen{$id};
    $dbh->do("DELETE FROM ifolders WHERE ifolderid = ?", {}, $id);
  }

  $Self->commit();

  if (keys %getstatus) {
    my $data = $Self->backend_cmd('imap_status', [keys %getstatus]);
    $Self->begin();
    foreach my $name (keys %$data) {
      my $status = $data->{$name};
      $Self->dmaybeupdate('ifolders', {
        uidvalidity => $status->{uidvalidity},
        uidnext => $status->{uidnext},
        uidfirst => $status->{uidnext},
        highestmodseq => $status->{highestmodseq},
      }, {ifolderid => $getstatus{$name}});
    }
    $Self->commit();
  }

  $Self->sync_jmailboxes();
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jmailboxes {
  my $Self = shift;
  $Self->begin();
  my $dbh = $Self->dbh();
  my $ifolders = $dbh->selectall_arrayref("SELECT ifolderid, sep, imapname, label, jmailboxid FROM ifolders");
  my $jmailboxes = $dbh->selectall_arrayref("SELECT jmailboxid, name, parentid, role, active FROM jmailboxes");

  my %jbyid;
  my %roletoid;
  my %byname;
  foreach my $mailbox (@$jmailboxes) {
    $jbyid{$mailbox->[0]} = $mailbox;
    $roletoid{$mailbox->[3]} = $mailbox->[0] if $mailbox->[3];
    $byname{$mailbox->[2]}{$mailbox->[1]} = $mailbox->[0];
  }

  my %seen;
  foreach my $folder (@$ifolders) {
    my $fname = $folder->[2];
    $fname =~ s/^INBOX\.//;
    # check for roles first
    my @bits = split "[$folder->[1]]", $fname;
    my $role = $ROLE_MAP{lc $fname};
    my $id = 0;
    my $parentid = 0;
    my $name;
    my $order = 3;
    $order = 2 if $role;
    $order = 1 if ($role||'') eq 'inbox';
    while (my $item = shift @bits) {
      $seen{$id} = 1 if $id;
      $name = $item;
      $parentid = $id;
      $id = $byname{$parentid}{$name};
      unless ($id) {
        if (@bits) {
          # need to create intermediate folder ...
          # XXX  - label noselect?
          $id = $Self->dmake('jmailboxes', {name => $name, order => 4, parentid => $parentid});
          $byname{$parentid}{$name} = $id;
        }
      }
    }
    next unless $name;
    my %details = (
      name => $name,
      parentid => $parentid,
      order => $order,
      mustBeOnly => 1,
      mayDelete => 0,
      mayRename => 0,
      mayAdd => 1,
      mayRemove => 1,
      mayChild => 0,
      mayRead => 1,
    );
    if ($id) {
      if ($role and $roletoid{$role} and $roletoid{$role} != $id) {
        # still gotta move it
        $id = $roletoid{$role};
        $Self->ddirty('jmailboxes', {active => 1, %details}, {jmailboxid => $id});
      }
      elsif (not $folder->[4]) {
        # reactivate!
        $Self->ddirty('jmailboxes', {active => 1}, {jmailboxid => $id});
      }
    }
    else {
      # case: role - we need to see if there's a case for moving this thing
      if ($role and $roletoid{$role}) {
        $id = $roletoid{$role};
        $Self->ddirty('jmailboxes', {active => 1, %details}, {jmailboxid => $id});
      }
      else {
        $id = $Self->dmake('jmailboxes', {role => $role, %details});
        $byname{$parentid}{$name} = $id;
        $roletoid{$role} = $id if $role;
      }
    }
    $seen{$id} = 1;
    $Self->dmaybeupdate('ifolders', {jmailboxid => $id}, {ifolderid => $folder->[0]});
  }

  foreach my $mailbox (@$jmailboxes) {
    my $id = $mailbox->[0];
    next if $seen{$id};
    $Self->dupdate('jmailboxes', {active => 0}, {jmailboxid => $id});
  }
  $Self->commit();
}

# synchronise list from CalDAV server to local folder cache
sub sync_calendars {
  my $Self = shift;

  my $calendars = $Self->backend_cmd('get_calendars', []);
  return unless $calendars;

  $Self->begin();
  my $dbh = $Self->dbh();

  my $icalendars = $dbh->selectall_arrayref("SELECT icalendarid, href, name, isReadOnly, color, syncToken FROM icalendars");
  my %byhref = map { $_->[1] => $_ } @$icalendars;

  my %seen;
  my @todo;
  foreach my $calendar (@$calendars) {
    my $id = $calendar->{href} ? $byhref{$calendar->{href}}[0] : 0;
    my $data = {
      isReadOnly => $calendar->{isReadOnly},
      href => $calendar->{href},
      color => $calendar->{color},
      name => $calendar->{name},
      syncToken => $calendar->{syncToken},
    };
    if ($id) {
      $Self->dmaybeupdate('icalendars', $data, {icalendarid => $id});
      my $token = $byhref{$calendar->{href}}[5];
      if ($token ne $calendar->{syncToken}) {
        push @todo, $id;
        $Self->dmaybeupdate('icalendars', $data, {icalendarid => $id});
      }
    }
    else {
      $id = $Self->dinsert('icalendars', $data);
      push @todo, $id;
    }
    $seen{$id} = 1;
  }

  foreach my $calendar (@$icalendars) {
    my $id = $calendar->[0];
    next if $seen{$id};
    $dbh->do("DELETE FROM icalendars WHERE icalendarid = ?", {}, $id);
  }

  $Self->commit();

  $Self->sync_jcalendars();

  foreach my $id (@todo) {
    $Self->do_calendar($id);
  }
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jcalendars {
  my $Self = shift;
  $Self->begin();
  my $dbh = $Self->dbh();
  my $icalendars = $dbh->selectall_arrayref("SELECT icalendarid, name, color, jcalendarid FROM icalendars");
  my $jcalendars = $dbh->selectall_arrayref("SELECT jcalendarid, name, color, active FROM jcalendars");

  my %jbyid;
  foreach my $calendar (@$jcalendars) {
    $jbyid{$calendar->[0]} = $calendar;
  }

  my %seen;
  foreach my $calendar (@$icalendars) {
    my $data = {
      name => $calendar->[1],
      color => $calendar->[2],
      isVisible => 1,
      mayReadFreeBusy => 1,
      mayReadItems => 1,
      mayAddItems => 0,
      mayModifyItems => 0,
      mayRemoveItems => 0,
      mayDelete => 0,
      mayRename => 0,
    };
    if ($calendar->[3] && $jbyid{$calendar->[3]}) {
      $Self->dmaybeupdate('jcalendars', $data, {jcalendarid => $calendar->[3]});
      $seen{$calendar->[3]} = 1;
    }
    else {
      my $id = $Self->dmake('jcalendars', $data);
      $Self->dupdate('icalendars', {jcalendarid => $id}, {icalendarid => $calendar->[0]});
      $seen{$id} = 1;
    }
  }

  foreach my $calendar (@$jcalendars) {
    my $id = $calendar->[0];
    next if $seen{$id};
    $Self->dupdate('jcalendars', {active => 0}, {jcalendarid => $id});
  }
  $Self->commit();
}

sub do_calendar {
  my $Self = shift;
  my $calendarid = shift;

  my $dbh = $Self->dbh();

  my ($href, $jcalendarid) = $dbh->selectrow_array("SELECT href, jcalendarid FROM icalendars WHERE icalendarid = ?", {}, $calendarid);
  my $events = $Self->backend_cmd('get_events', {href => $href});

  $Self->begin();
  my $exists = $dbh->selectall_arrayref("SELECT ieventid, resource, content FROM ievents WHERE icalendarid = ?", {}, $calendarid);
  my %res = map { $_->[1] => $_ } @$exists;

  foreach my $resource (keys %$events) {
    my $data = delete $res{$resource};
    my $raw = $events->{$resource};
    if ($data) {
      my $id = $data->[0];
      next if $raw eq $data->[2];
      $Self->dmaybeupdate('ievents', {content => $raw, resource => $resource}, {ieventid => $id});
    }
    else {
      $Self->dinsert('ievents', {content => $raw, resource => $resource});
    }
    my $event = $Self->parse_event($raw);
    $Self->set_event($jcalendarid, $event);
  }

  foreach my $resource (keys %res) {
    my $data = delete $res{$resource};
    my $id = $data->[0];
    $Self->ddelete('ievents', {ieventid => $id});
    my $event = $Self->parse_event($data->[2]);
    $Self->delete_event($jcalendarid, $event->{uid});
  }

  $Self->commit();
}

# synchronise list from CardDAV server to local folder cache
# call in transaction
sub sync_addressbooks {
  my $Self = shift;

  my $addressbooks = $Self->backend_cmd('get_addressbooks', []);
  return unless $addressbooks;

  $Self->begin();
  my $dbh = $Self->dbh();

  my $iaddressbooks = $dbh->selectall_arrayref("SELECT iaddressbookid, href, name, isReadOnly, syncToken FROM iaddressbooks");
  my %byhref = map { $_->[1] => $_ } @$iaddressbooks;

  my %seen;
  my @todo;
  foreach my $addressbook (@$addressbooks) {
    my $id = $byhref{$addressbook->{href}}[0];
    my $data = {
      isReadOnly => $addressbook->{isReadOnly},
      href => $addressbook->{href},
      name => $addressbook->{name},
      syncToken => $addressbook->{syncToken},
    };
    if ($id) {
      my $token = $byhref{$addressbook->{href}}[4];
      if ($token ne $addressbook->{syncToken}) {
        push @todo, $id;
        $Self->dmaybeupdate('iaddressbooks', $data, {iaddressbookid => $id});
      }
    }
    else {
      $id = $Self->dinsert('iaddressbooks', $data);
      push @todo, $id;
    }
    $seen{$id} = 1;
  }

  foreach my $addressbook (@$iaddressbooks) {
    my $id = $addressbook->[0];
    next if $seen{$id};
    $dbh->do("DELETE FROM iaddressbooks WHERE iaddressbookid = ?", {}, $id);
  }

  $Self->commit();

  $Self->sync_jaddressbooks();

  foreach my $id (@todo) {
    $Self->do_addressbook($id);
  }
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jaddressbooks {
  my $Self = shift;
  $Self->begin();
  my $dbh = $Self->dbh();
  my $iaddressbooks = $dbh->selectall_arrayref("SELECT iaddressbookid, name, jaddressbookid FROM iaddressbooks");
  my $jaddressbooks = $dbh->selectall_arrayref("SELECT jaddressbookid, name, active FROM jaddressbooks");

  my %jbyid;
  foreach my $addressbook (@$jaddressbooks) {
    $jbyid{$addressbook->[0]} = $addressbook;
  }

  my %seen;
  foreach my $addressbook (@$iaddressbooks) {
    my $data = {
      name => $addressbook->[1],
      isVisible => 1,
      mayReadItems => 1,
      mayAddItems => 0,
      mayModifyItems => 0,
      mayRemoveItems => 0,
      mayDelete => 0,
      mayRename => 0,
    };
    if ($addressbook->[2] && $jbyid{$addressbook->[2]}) {
      $Self->dmaybeupdate('jaddressbooks', $data, {jaddressbookid => $addressbook->[2]});
      $seen{$addressbook->[2]} = 1;
    }
    else {
      my $id = $Self->dmake('jaddressbooks', $data);
      $Self->dupdate('iaddressbooks', {jaddressbookid => $id}, {iaddressbookid => $addressbook->[0]});
      $seen{$id} = 1;
    }
  }

  foreach my $addressbook (@$jaddressbooks) {
    my $id = $addressbook->[0];
    next if $seen{$id};
    $Self->dupdate('jaddressbooks', {active => 0}, {jaddressbookid => $id});
  }
  $Self->commit();
}

sub do_addressbook {
  my $Self = shift;
  my $addressbookid = shift;

  my $dbh = $Self->dbh();

  my ($href, $jaddressbookid) = $dbh->selectrow_array("SELECT href, jaddressbookid FROM iaddressbooks WHERE iaddressbookid = ?", {}, $addressbookid);
  my $cards = $Self->backend_cmd('get_cards', {href => $href});

  $Self->begin();

  my $exists = $dbh->selectall_arrayref("SELECT icardid, resource, content FROM icards WHERE iaddressbookid = ?", {}, $addressbookid);
  my %res = map { $_->[1] => $_ } @$exists;

  foreach my $resource (keys %$cards) {
    my $data = delete $res{$resource};
    my $raw = $cards->{$resource};
    if ($data) {
      my $id = $data->[0];
      next if $raw eq $data->[2];
      $Self->dmaybeupdate('icards', {content => $raw, resource => $resource}, {icardid => $id});
    }
    else {
      $Self->dinsert('icards', {content => $raw, resource => $resource});
    }
    my $card = $Self->parse_card($raw);
    $Self->set_card($jaddressbookid, $card);
  }

  foreach my $resource (keys %res) {
    my $data = delete $res{$resource};
    my $id = $data->[0];
    $Self->ddelete('icards', {icardid => $id});
    my $card = $Self->parse_card($data->[2]);
    $Self->delete_card($jaddressbookid, $card->{uid}, $card->{kind});
  }
  $Self->commit();
}

sub labels {
  my $Self = shift;
  unless ($Self->{labels}) {
    my $data = $Self->dbh->selectall_arrayref("SELECT label, ifolderid, jmailboxid, imapname FROM ifolders");
    $Self->{labels} = { map { lc $_->[0] => [$_->[1], $_->[2], $_->[3]] } @$data };
  }
  return $Self->{labels};
}

sub sync_imap {
  my $Self = shift;
  my $data = $Self->dbh->selectall_arrayref("SELECT ifolderid, imapname, uidvalidity, highestmodseq, label FROM ifolders");
  my @imapnames = map { $_->[1] } @$data;
  my $status = $Self->backend_cmd('imap_status', \@imapnames);

  foreach my $row (@$data) {
    # XXX - better handling of UIDvalidity change?
    next if ($status->{$row->[1]}{uidvalidity} == $row->[2] and $status->{$row->[1]}{highestmodseq} and $status->{$row->[1]}{highestmodseq} == $row->[3]);
    $Self->do_folder($row->[0], $row->[4]);
  }
}

sub backfill {
  my $Self = shift;
  my $data = $Self->dbh->selectall_arrayref("SELECT ifolderid,label FROM ifolders WHERE uidnext > 1 AND uidfirst > 1 ORDER BY mtime");
  return unless @$data;
  my $rest = 50;
  foreach my $row (@$data) {
    $rest -= $Self->do_folder(@$row, $rest);
    last if $rest < 10;
  }
  return 1;
}

sub firstsync {
  my $Self = shift;

  $Self->sync_folders();

  my $labels = $Self->labels();

  my $ifolderid = $labels->{"inbox"}[0];
  $Self->do_folder($ifolderid, "inbox", 50);

  my $msgids = $Self->dbh->selectcol_arrayref("SELECT msgid FROM imessages WHERE ifolderid = ? ORDER BY uid DESC LIMIT 50", {}, $ifolderid);

  # pre-load the INBOX!
  $Self->fill_messages(@$msgids);
}

sub calcmsgid {
  my $Self = shift;
  my $imapname = shift;
  my $uid = shift;
  my $data = shift;
  my $envelope = $data->{envelope};
  my $json = JSON::XS->new->allow_nonref->canonical;
  my $coded = $json->encode([$envelope, $data->{'rfc822.size'}]);
  my $msgid = 's' . substr(sha1_hex($coded), 0, 11);

  my $replyto = lc($envelope->{'In-Reply-To'} || '');
  my $messageid = lc($envelope->{'Message-ID'} || '');
  my ($thrid) = $Self->dbh->selectrow_array("SELECT DISTINCT thrid FROM ithread WHERE messageid IN (?, ?)", {}, $replyto, $messageid);
  $thrid ||= $msgid;
  foreach my $id ($replyto, $messageid) {
    next if $id eq '';
    $Self->dbh->do("INSERT OR IGNORE INTO ithread (messageid, thrid) VALUES (?, ?)", {}, $id, $thrid);
  }

  return ($msgid, $thrid);
}

sub do_folder {
  my $Self = shift;
  my $ifolderid = shift;
  my $forcelabel = shift;
  my $batchsize = shift;

  Carp::confess("NO FOLDERID") unless $ifolderid;
  $Self->begin();
  my $dbh = $Self->dbh();

  my ($imapname, $uidfirst, $uidnext, $uidvalidity, $highestmodseq) =
     $dbh->selectrow_array("SELECT imapname, uidfirst, uidnext, uidvalidity, highestmodseq FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
  die "NO SUCH FOLDER $ifolderid" unless $imapname;

  my %fetches;

  if ($batchsize) {
    if ($uidfirst > 1) {
      my $end = $uidfirst - 1;
      $uidfirst -= $batchsize;
      $uidfirst = 1 if $uidfirst < 1;
      $fetches{backfill} = [$uidfirst, $end, [qw(internaldate envelope rfc822.size)]];
    }
  }
  else {
    $fetches{new} = [$uidnext, '*', [qw(internaldate envelope rfc822.size)]];
    $fetches{update} = [$uidfirst, $uidnext - 1, [], $highestmodseq];
  }

  $Self->commit();

  return unless keys %fetches;

  my $res = $Self->backend_cmd('imap_fetch', $imapname, {
    uidvalidity => $uidvalidity,
    highestmodseq => $highestmodseq,
    uidnext => $uidnext,
  }, \%fetches);

  if ($res->{newstate}{uidvalidity} != $uidvalidity) {
    # going to want to nuke everything for the existing folder and create this - but for now, just die
    die "UIDVALIDITY CHANGED $imapname: $uidvalidity => $res->{newstate}{uidvalidity}";
  }

  $Self->begin();

  my $didold = 0;
  if ($res->{backfill}) {
    my $new = $res->{backfill}[1];
    $Self->{backfilling} = 1;
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
      $didold++;
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, [$forcelabel], $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
    delete $Self->{backfilling};
  }

  if ($res->{update}) {
    my $changed = $res->{update}[1];
    foreach my $uid (sort { $a <=> $b } keys %$changed) {
      $Self->changed_record($ifolderid, $uid, $changed->{$uid}{'flags'}, [$forcelabel]);
    }
  }

  if ($res->{new}) {
    my $new = $res->{new}[1];
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, [$forcelabel], $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  $Self->dupdate('ifolders', {highestmodseq => $res->{newstate}{highestmodseq}, uidfirst => $uidfirst, uidnext => $res->{newstate}{uidnext}}, {ifolderid => $ifolderid});

  $Self->commit();

  # need to make changes before counting
  my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
  # if we don't know everything, we have to ALWAYS check or moves break
  if ($uidfirst != 1 or $count != $res->{newstate}{exists}) {
    # welcome to the future
    $uidnext = $res->{newstate}{uidnext};
    my $to = $uidnext - 1;
    $Self->log('debug', "COUNTING $imapname: $uidfirst:$to (something deleted)");
    my $res = $Self->backend_cmd('imap_count', $imapname, $uidvalidity, "$uidfirst:$to");
    $Self->begin();
    my $uids = $res->{data};
    my $data = $dbh->selectcol_arrayref("SELECT uid FROM imessages WHERE ifolderid = ? AND uid >= ?", {}, $ifolderid, $uidfirst);
    my %exists = map { $_ => 1 } @$uids;
    foreach my $uid (@$data) {
      next if $exists{$uid};
      $Self->deleted_record($ifolderid, $uid);
    }
    $Self->commit();
  }

  return $didold;
}

sub changed_record {
  my $Self = shift;
  my ($folder, $uid, $flaglist, $labellist) = @_;

  my $flags = encode_json([sort @$flaglist]);
  my $labels = encode_json([sort @$labellist]);

  my ($msgid) = $Self->{dbh}->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $folder, $uid);

  $Self->dmaybeupdate('imessages', {flags => $flags, labels => $labels}, {ifolderid => $folder, uid => $uid});

  $Self->apply_data($msgid, $flaglist, $labellist);
}

sub update_messages {
  my $Self = shift;
  my $changes = shift;

  my $dbh = $Self->{dbh};

  my %updatemap;
  my %notchanged;
  foreach my $msgid (keys %$changes) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    if ($ifolderid and $uid) {
      $updatemap{$ifolderid}{$uid} = $msgid;
    }
    else {
      $notchanged{$msgid} = "No such message on server";
    }
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, uidvalidity, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[4] => $_ } @$folderdata;

  my @changed;
  foreach my $ifolderid (keys %updatemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    my $uidvalidity = $foldermap{$ifolderid}[2];

    foreach my $uid (sort keys %{$updatemap{$ifolderid}}) {
      my $msgid = $updatemap{$ifolderid}{$uid};
      my $action = $changes->{$msgid};
      unless ($imapname and $uidvalidity) {
        $notchanged{$msgid} = "No folder found";
        next;
      }
      if (exists $action->{isUnread}) {
        my $bool = !$action->{isUnread};
        my @flags = ("\\Seen");
        $Self->log('debug', "STORING $bool @flags for $uid");
        $Self->backend_cmd('imap_update', $imapname, $uidvalidity, $uid, $bool, \@flags);
      }
      if (exists $action->{isFlagged}) {
        my $bool = $action->{isFlagged};
        my @flags = ("\\Flagged");
        $Self->log('debug', "STORING $bool @flags for $uid");
        $Self->backend_cmd('imap_update', $imapname, $uidvalidity, $uid, $bool, \@flags);
      }
      if (exists $action->{isAnswered}) {
        my $bool = $action->{isAnswered};
        my @flags = ("\\Answered");
        $Self->log('debug', "STORING $bool @flags for $uid");
        $Self->backend_cmd('imap_update', $imapname, $uidvalidity, $uid, $bool, \@flags);
      }
      if (exists $action->{mailboxIds}) {
        my $id = $action->{mailboxIds}->[0]; # there can be only one
        my $newfolder = $foldermap{$id}[1];
        $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uid, $newfolder);
      }
      # XXX - handle errors from backend commands
      push @changed, $msgid;
    }
  }

  return (\@changed, \%notchanged);
}

sub delete_messages {
  my $Self = shift;
  my $ids = shift;

  my $dbh = $Self->{dbh};

  my %deletemap;
  my %notdeleted;
  foreach my $msgid (@$ids) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    if ($ifolderid and $uid) {
      $deletemap{$ifolderid}{$uid} = $msgid;
    }
    else {
      $notdeleted{$msgid} = "No such message on server";
    }
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, uidvalidity, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[4] => $_ } grep { $_->[4] } @$folderdata;

  my @deleted;
  foreach my $ifolderid (keys %deletemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    my $uidvalidity = $foldermap{$ifolderid}[2];
    unless ($imapname) {
      $notdeleted{$_} = "No folder" for values %{$deletemap{$ifolderid}};
    }
    my $uids = [sort keys %{$deletemap{$ifolderid}}];
    $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uids, undef); # no destination folder
    push @deleted, values %{$deletemap{$ifolderid}};
  }
  return (\@deleted, \%notdeleted);
}

sub deleted_record {
  my $Self = shift;
  my ($folder, $uid) = @_;

  my ($msgid, $jmailboxid) = $Self->{dbh}->selectrow_array("SELECT msgid, jmailboxid FROM imessages JOIN ifolders USING (ifolderid) WHERE imessages.ifolderid = ? AND uid = ?", {}, $folder, $uid);
  return unless $msgid;

  $Self->ddelete('imessages', {ifolderid => $folder, uid => $uid});

  $Self->delete_message_from_mailbox($msgid, $jmailboxid);
}

sub new_record {
  my $Self = shift;
  my ($ifolderid, $uid, $flaglist, $labellist, $envelope, $internaldate, $msgid, $thrid, $size) = @_;

  my $flags = encode_json([sort @$flaglist]);
  my $labels = encode_json([sort @$labellist]);

  my $data = {
    ifolderid => $ifolderid,
    uid => $uid,
    flags => $flags,
    labels => $labels,
    internaldate => $internaldate,
    msgid => $msgid,
    thrid => $thrid,
    envelope => encode_json($envelope),
    size => $size,
  };

  # XXX - what about dupes?
  $Self->dinsert('imessages', $data);

  $Self->apply_data($msgid, $flaglist, $labellist);
}

sub apply_data {
  my $Self = shift;
  my ($msgid, $flaglist, $labellist) = @_;

  # spurious temporary old message during move
  return if grep { lc $_ eq '\\deleted' } @$flaglist;

  my %flagdata = (
    isUnread => 1,
    isFlagged => 0,
    isAnswered => 0,
    isDraft => 0,
  );
  foreach my $flag (@$flaglist) {
    $flagdata{isUnread} = 0 if lc $flag eq '\\seen';
    $flagdata{isFlagged} = 1 if lc $flag eq '\\flagged';
    $flagdata{isAnswered} = 1 if lc $flag eq '\\answered';
    $flagdata{isDraft} = 1 if lc $flag eq '\\draft';
  }

  my $labels = $Self->labels();
  my @jmailboxids = grep { $_ } map { $labels->{lc $_}[1] } @$labellist;

  my ($old) = $Self->{dbh}->selectrow_array("SELECT msgid FROM jmessages WHERE msgid = ? AND active = 1", {}, $msgid);

  $Self->log('debug', "DATA (@jmailboxids) for $msgid");

  if ($old) {
    $Self->log('debug', "changing $msgid");
    return $Self->change_message($msgid, \%flagdata, \@jmailboxids);
  }
  else {
    $Self->log('debug', "adding $msgid");
    my $data = $Self->dbh->selectrow_hashref("SELECT thrid,internaldate,size,envelope FROM imessages WHERE msgid = ?", {}, $msgid);
    return $Self->add_message({
      msgid => $msgid,
      internaldate => $data->{internaldate},
      thrid => $data->{thrid},
      msgsize => $data->{size},
      _envelopedata($data->{envelope}),
      %flagdata,
    }, \@jmailboxids);
  }
}

sub _envelopedata {
  my $data = shift;
  my $envelope = decode_json($data);
  my $encsub = decode('MIME-Header', $envelope->{Subject});
  return (
    msgsubject => $encsub,
    msgfrom => $envelope->{From},
    msgto => $envelope->{To},
    msgcc => $envelope->{Cc},
    msgbcc => $envelope->{Bcc},
    msgdate => str2time($envelope->{Date}),
    msginreplyto => $envelope->{'In-Reply-To'},
    msgmessageid => $envelope->{'Message-ID'},
  );
}

sub fill_messages {
  my $Self = shift;
  my @ids = @_;

  my $data = $Self->dbh->selectall_arrayref("SELECT msgid, parsed FROM jrawmessage WHERE msgid IN (" . join(', ', map { "?" } @ids) . ")", {}, @ids);
  my %result;
  foreach my $line (@$data) {
    $result{$line->[0]} = decode_json($line->[1]);
  }
  my @need = grep { not $result{$_} } @ids;

  return \%result unless @need;

  my $uids = $Self->dbh->selectall_arrayref("SELECT ifolderid, uid, msgid FROM imessages WHERE msgid IN (" . join(', ', map { "?" } @need) . ")", {}, @need);
  my %udata;
  foreach my $row (@$uids) {
    $udata{$row->[0]}{$row->[1]} = $row->[2];
  }

  foreach my $ifolderid (sort keys %udata) {
    my $uhash = $udata{$ifolderid};
    my $uids = join(',', sort { $a <=> $b } grep { not $result{$uhash->{$_}} } keys %$uhash);
    next unless $uids;

    my ($imapname, $uidvalidity) = $Self->dbh->selectrow_array("SELECT imapname, uidvalidity FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
    next unless $imapname;

    my $res = $Self->backend_cmd('imap_fill', $imapname, $uidvalidity, $uids);

    $Self->begin();

    foreach my $uid (sort { $a <=> $b } keys %{$res->{data}}) {
      my $msgid = $uhash->{$uid};
      next if $result{$msgid};
      my $rfc822 = $res->{data}{$uid};
      next unless $rfc822;
      $result{$msgid} = $Self->add_raw_message($msgid, $rfc822);
    }

    $Self->commit();
  }

  my @stillneed = grep { not $result{$_} } @ids;

  return \%result;
}

sub _initdb {
  my $Self = shift;
  my $dbh = shift;

  $Self->SUPER::_initdb($dbh);

  # XXX - password encryption?
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iserver (
  username TEXT PRIMARY KEY,
  password TEXT,
  hostname TEXT,
  lastfoldersync DATE,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ifolders (
  ifolderid INTEGER PRIMARY KEY NOT NULL,
  jmailboxid INTEGER,
  sep TEXT NOT NULL,
  imapname TEXT NOT NULL,
  label TEXT,
  uidvalidity INTEGER,
  uidfirst INTEGER,
  uidnext INTEGER,
  highestmodseq INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS imessages (
  imessageid INTEGER PRIMARY KEY NOT NULL,
  ifolderid INTEGER,
  uid INTEGER,
  internaldate DATE,
  modseq INTEGER,
  flags TEXT,
  labels TEXT,
  thrid TEXT,
  msgid TEXT,
  envelope TEXT,
  bodystructure TEXT,
  size INTEGER,
  mtime DATE NOT NULL
);
EOF
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ithread (
  messageid TEXT PRIMARY KEY,
  thrid TEXT
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icalendars (
  icalendarid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  color TEXT,
  syncToken TEXT,
  jcalendarid INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ievents (
  ieventid INTEGER PRIMARY KEY NOT NULL,
  icalendarid INTEGER,
  resource TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iaddressbooks (
  iaddressbookid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  syncToken TEXT,
  jaddressbookid INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icards (
  icardid INTEGER PRIMARY KEY NOT NULL,
  iaddressbookid INTEGER,
  resource TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

}

1;
