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
use Digest::SHA qw(sha1_hex);
use Encode;
use Encode::MIME::Header;
use AnyEvent;
use AnyEvent::Socket;
use Date::Format;
use Data::Dumper;
use JMAP::Sync::Gmail;
use JMAP::Sync::Standard;

our $TAG = 1;

# special use or name magic
my %ROLE_MAP = (
  'inbox' => 'inbox',

  'drafts' => 'drafts',
  'draft' => 'drafts',
  'draft messages' => 'drafts',

  'bulk' => 'spam',
  'bulk mail' => 'spam',
  'junk' => 'spam',
  'junk mail' => 'spam',
  'spam' => 'spam',
  'spam mail' => 'spam',
  'spam messages' => 'spam',

  'archive' => 'archive',
  'sent' => 'sent',
  'sent items' => 'sent',
  'sent messages' => 'sent',

  'deleted messages' => 'trash',
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
  my $args = shift;
  # XXX - picture, etc

  $Self->begin();

  my $data = $Self->dbh->selectrow_arrayref("SELECT username FROM iserver");
  if ($data and $data->[0]) {
    $Self->dmaybeupdate('iserver', $args);
  }
  else {
    $Self->dinsert('iserver', $args);
  }

  my $user = $Self->dbh->selectrow_arrayref("SELECT email FROM account");
  if ($user and $user->[0]) {
    $Self->dmaybeupdate('account', {email => $args->{username}});
  }
  else {
    $Self->dinsert('account', {
      email => $args->{username},
      jdeletedmodseq => 0,
      jhighestmodseq => 1,
    });
  }

  $Self->commit();
}

sub access_token {
  my $Self = shift;
  my ($hostname, $username, $password) = $Self->dbh->selectrow_array("SELECT imapHost, username, password FROM iserver");

  return [$hostname, $username, $password];
}

sub access_data {
  my $Self = shift;

  my $config = $Self->dbh->selectall_arrayref("SELECT * FROM iserver", {Slice => {}});

  return $config->[0];
}

# synchronous backend for now
sub backend_cmd {
  my $Self = shift;
  my $cmd = shift;
  my @args = @_;

  use Carp;
  Carp::confess("in transaction") if $Self->in_transaction();

  unless ($Self->{backend}) {
    my $config = $Self->access_data();
    my $backend;
    if ($config->{imapHost} eq 'imap.gmail.com') {
      $backend = JMAP::Sync::Gmail->new($config) || die "failed to setup $config->{username}";
    } else {
      $backend = JMAP::Sync::Standard->new($config) || die "failed to setup $config->{username}";
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

  my $data = $Self->backend_cmd('folders');
  my ($prefix, $folders) = @$data;

  $Self->begin();
  my $dbh = $Self->dbh();

  my $ifolders = $dbh->selectall_arrayref("SELECT ifolderid, sep, uidvalidity, imapname, label FROM ifolders");
  my %ibylabel = map { $_->[4] => $_ } @$ifolders;
  my %seen;

  my %getstatus;
  foreach my $name (sort keys %$folders) {
    my $sep = $folders->{$name}[0];
    my $label = $folders->{$name}[1];
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

  $Self->dmaybeupdate('iserver', {imapPrefix => $prefix, lastfoldersync => time()});

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
  my $jmailboxes = $dbh->selectall_arrayref("SELECT jmailboxid, name, parentId, role, active FROM jmailboxes");

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
    # check for roles first
    my @bits = split "[$folder->[1]]", $fname;
    shift @bits if ($bits[0] eq 'INBOX' and $bits[1]); # otehrwise we get none...
    shift @bits if $bits[0] eq '[Gmail]';
    my $role = $ROLE_MAP{lc $folder->[3]};
    my $id = 0;
    my $parentId = 0;
    my $name;
    my $sortOrder = 3;
    $sortOrder = 2 if $role;
    $sortOrder = 1 if ($role||'') eq 'inbox';
    while (my $item = shift @bits) {
      $seen{$id} = 1 if $id;
      $name = $item;
      $parentId = $id;
      $id = $byname{$parentId}{$name};
      unless ($id) {
        if (@bits) {
          # need to create intermediate folder ...
          # XXX  - label noselect?
          $id = $Self->dmake('jmailboxes', {name => $name, sortOrder => 4, parentId => $parentId});
          $byname{$parentId}{$name} = $id;
        }
      }
    }
    next unless $name;
    my %details = (
      name => $name,
      parentId => $parentId,
      sortOrder => $sortOrder,
      mustBeOnlyMailbox => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayRemoveItems => 1,
      mayCreateChild => 1,
      mayRename => $role ? 0 : 1,
      mayDelete => $role ? 0 : 1,
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
        $byname{$parentId}{$name} = $id;
        $roletoid{$role} = $id if $role;
      }
    }
    $seen{$id} = 1;
    $Self->dmaybeupdate('ifolders', {jmailboxid => $id}, {ifolderid => $folder->[0]});
  }

  if ($roletoid{'outbox'}) {
    $seen{$roletoid{'outbox'}} = 1;
  }
  else {
    # outbox - magic
    my $outbox = {
      parentId => 0,
      name => 'Outbox',
      role => 'outbox',
      sortOrder => 2,
      mustBeOnlyMailbox => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayRemoveItems => 1,
      mayCreateChild => 0,
      mayRename => 0,
      mayDelete => 0,
    };
    my $id = $Self->dmake('jmailboxes', $outbox);
    $seen{$id} = 1;
    $roletoid{'outbox'} = $id;
  }

  if ($roletoid{'archive'}) {
    $seen{$roletoid{'archive'}} = 1;
  }
  else {
    # archive - magic
    my $archive = {
      parentId => 0,
      name => 'Archive',
      role => 'archive',
      sortOrder => 2,
      mustBeOnlyMailbox => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayRemoveItems => 1,
      mayCreateChild => 0,
      mayRename => 0,
      mayDelete => 0,
    };
    my $id = $Self->dmake('jmailboxes', $archive);
    $seen{$id} = 1;
    $roletoid{'archive'} = $id;
  }

  foreach my $mailbox (@$jmailboxes) {
    my $id = $mailbox->[0];
    next unless $mailbox->[4];
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
      mayAddItems => 1,
      mayModifyItems => 1,
      mayRemoveItems => 1,
      mayDelete => 1,
      mayRename => 1,
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
  my $events = $Self->backend_cmd('get_events', $href);
  # parse events before we lock
  my %parsed = map { $_ => $Self->parse_event($events->{$_}) } keys %$events;

  $Self->begin();
  my $exists = $dbh->selectall_arrayref("SELECT ieventid, resource, uid FROM ievents WHERE icalendarid = ?", {Slice => {}}, $calendarid);
  my %res = map { $_->{resource} => $_ } @$exists;

  foreach my $resource (keys %$events) {
    my $data = delete $res{$resource};
    my $raw = $events->{$resource};
    my $event = $parsed{$resource};
    my $uid = $event->{uid};
    my $item = {
      icalendarid => $calendarid,
      uid => $uid,
      resource => $resource,
      content => $raw,
    };
    if ($data) {
      my $id = $data->{ieventid};
      $Self->dmaybeupdate('ievents', $item, {ieventid => $id});
    }
    else {
      $Self->dinsert('ievents', $item);
    }
    $Self->set_event($jcalendarid, $event);
  }

  foreach my $resource (keys %res) {
    my $data = delete $res{$resource};
    my $id = $data->{ieventid};
    $Self->ddelete('ievents', {ieventid => $id});
    $Self->delete_event($jcalendarid, $data->{uid});
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

  my $iaddressbooks = $dbh->selectall_arrayref("SELECT iaddressbookid, href, syncToken FROM iaddressbooks", {Slice => {}});
  my %byhref = map { $_->{href} => $_ } @$iaddressbooks;

  my %seen;
  my @todo;
  foreach my $addressbook (@$addressbooks) {
    my $id = $byhref{$addressbook->{href}}{iaddressbookid};
    my $data = {
      isReadOnly => $addressbook->{isReadOnly},
      href => $addressbook->{href},
      name => $addressbook->{name},
      syncToken => $addressbook->{syncToken},
    };
    if ($id) {
      my $token = $byhref{$addressbook->{href}}{syncToken};
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
    my $id = $addressbook->{iaddressbookid};
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

  my $iaddressbooks = $dbh->selectall_arrayref("SELECT iaddressbookid, name, jaddressbookid FROM iaddressbooks", {Slice => {}});
  my $jaddressbooks = $dbh->selectall_arrayref("SELECT jaddressbookid, name, active FROM jaddressbooks", {Slice => {}});

  my %jbyid;
  foreach my $addressbook (@$jaddressbooks) {
    $jbyid{$addressbook->{jaddressbookid}} = $addressbook;
  }

  my %seen;
  foreach my $addressbook (@$iaddressbooks) {
    my $aid = $addressbook->{iaddressbooks};
    my $data = {
      name => $addressbook->{name},
      isVisible => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayModifyItems => 1,
      mayRemoveItems => 1,
      mayDelete => 0,
      mayRename => 0,
    };
    my $jid = $addressbook->{jaddressbookid};
    if ($jid && $jbyid{$jid}) {
      $Self->dmaybeupdate('jaddressbooks', $data, {jaddressbookid => $jid});
      $seen{$jid} = 1;
    }
    else {
      $jid = $Self->dmake('jaddressbooks', $data);
      $Self->dupdate('iaddressbooks', {jaddressbookid => $jid}, {iaddressbookid => $aid});
      $seen{$jid} = 1;
    }
  }

  foreach my $addressbook (@$jaddressbooks) {
    my $jid = $addressbook->{jaddressbookid};
    next if $seen{$jid};
    $Self->dupdate('jaddressbooks', {active => 0}, {jaddressbookid => $jid});
  }
  $Self->commit();
}

sub do_addressbook {
  my $Self = shift;
  my $addressbookid = shift;

  my $dbh = $Self->dbh();

  my ($href, $jaddressbookid) = $dbh->selectrow_array("SELECT href, jaddressbookid FROM iaddressbooks WHERE iaddressbookid = ?", {}, $addressbookid);
  my $cards = $Self->backend_cmd('get_cards', $href);
  # parse before locking
  my %parsed = map { $_ => $Self->parse_card($cards->{$_}) } keys %$cards;

  $Self->begin();

  my $exists = $dbh->selectall_arrayref("SELECT icardid, resource, uid, kind FROM icards WHERE iaddressbookid = ?", {Slice => {}}, $addressbookid);
  my %res = map { $_->{resource} => $_ } @$exists;

  foreach my $resource (keys %$cards) {
    my $data = delete $res{$resource};
    my $raw = $cards->{$resource};
    my $card = $parsed{$resource};
    my $uid = $card->{uid};
    my $kind = $card->{kind};
    my $item = {
      iaddressbookid => $addressbookid,
      resource => $resource,
      uid => $uid,
      kind => $kind,
      content => $raw,
    };
    if ($data) {
      my $id = $data->{icardid};
      $Self->dmaybeupdate('icards', $item, {icardid => $id});
    }
    else {
      $Self->dinsert('icards', $item);
    }
    $Self->set_card($jaddressbookid, $card);
  }

  foreach my $resource (keys %res) {
    my $data = delete $res{$resource};
    my $id = $data->{icardid};
    $Self->ddelete('icards', {icardid => $id});
    $Self->delete_card($jaddressbookid, $data->{uid}, $data->{kind});
  }

  $Self->commit();
}

sub labels {
  my $Self = shift;
  unless ($Self->{labels}) {
    my $data = $Self->dbh->selectall_arrayref("SELECT label, ifolderid, jmailboxid, imapname FROM ifolders");
    $Self->{labels} = { map { $_->[0] => [$_->[1], $_->[2], $_->[3]] } @$data };
  }
  return $Self->{labels};
}

sub sync_imap {
  my $Self = shift;
  my $data = $Self->dbh->selectall_arrayref("SELECT * FROM ifolders", {Slice => {}});
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }

  my @imapnames = map { $_->{imapname} } @$data;
  my $status = $Self->backend_cmd('imap_status', \@imapnames);

  foreach my $row (@$data) {
    # XXX - better handling of UIDvalidity change?
    next if ($status->{$row->{imapname}}{uidvalidity} == $row->{uidvalidity} and $status->{$row->{imapname}}{highestmodseq} and $status->{$row->{imapname}}{highestmodseq} == $row->{highestmodseq});
    my $label = $row->{label};
    $label = undef if lc $label eq '\\allmail';
    $Self->do_folder($row->{ifolderid}, $label);
  }
}

sub backfill {
  my $Self = shift;
  my $data = $Self->dbh->selectall_arrayref("SELECT * FROM ifolders WHERE uidnext > 1 AND uidfirst > 1 ORDER BY mtime", {Slice => {}});
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }

  return unless @$data;

  my $rest = 500;
  foreach my $row (@$data) {
    my $id = $row->{ifolderid};
    my $label = $row->{label};
    $label = undef if lc $label eq '\\allmail';
    $rest -= $Self->do_folder($id, $label, $rest);
    last if $rest < 10;
  }

  return 1;
}

sub firstsync {
  my $Self = shift;

  $Self->sync_folders();

  my $data = $Self->dbh->selectall_arrayref("SELECT * FROM ifolders", {Slice => {}});

  if ($Self->{is_gmail}) {
    my ($folder) = grep { lc $_->{label} eq '\\allmail' } @$data;
    $Self->do_folder($folder->{ifolderid}, undef, 50) if $folder;
  }
  else {
    my ($folder) = grep { lc $_->{imapname} eq 'inbox' } @$data;
    $Self->do_folder($folder->{ifolderid}, $folder->{label}, 50) if $folder;
  }
}

sub _trimh {
  my $val = shift;
  return '' unless defined $val;
  $val =~ s{\s+$}{};
  $val =~ s{^\s+}{};
  return $val;
}

sub calcmsgid {
  my $Self = shift;
  my $imapname = shift;
  my $uid = shift;
  my $data = shift;
  my $envelope = $data->{envelope};
  my $json = JSON::XS->new->allow_nonref->canonical;
  my $coded = $json->encode([$envelope, $data->{'rfc822.size'}]);
  my $base = substr(sha1_hex($coded), 0, 9);
  my $msgid = "m$base";

  my $replyto = _trimh($envelope->{'In-Reply-To'});
  my $messageid = _trimh($envelope->{'Message-ID'});
  my ($thrid) = $Self->dbh->selectrow_array("SELECT DISTINCT thrid FROM ithread WHERE messageid IN (?, ?)", {}, $replyto, $messageid);
  $thrid ||= "t$base";
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
  my @immutable = qw(internaldate envelope rfc822.size);
  my @mutable;
  if ($Self->{is_gmail}) {
    push @immutable, qw(x-gm-msgid x-gm-thrid x-gm-labels);
    push @mutable, qw(x-gm-labels);
  }

  if ($batchsize) {
    if ($uidfirst > 1) {
      my $end = $uidfirst - 1;
      $uidfirst -= $batchsize;
      $uidfirst = 1 if $uidfirst < 1;
      $fetches{backfill} = [$uidfirst, $end, [@immutable, @mutable]];
    }
  }
  else {
    $fetches{new} = [$uidnext, '*', [@immutable, @mutable]];
    $fetches{update} = [$uidfirst, $uidnext - 1, [@mutable], $highestmodseq];
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
  $Self->{t}{backfilling} = 1 if $batchsize;

  my $didold = 0;
  if ($res->{backfill}) {
    my $new = $res->{backfill}[1];
    $Self->{backfilling} = 1;
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid, @labels);
      if ($Self->{is_gmail}) {
        ($msgid, $thrid) = ($new->{$uid}{"x-gm-msgid"}, $new->{$uid}{"x-gm-thrid"});
        @labels = $forcelabel ? ($forcelabel) : @{$new->{$uid}{"x-gm-labels"}};
      }
      else {
        ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
        @labels = ($forcelabel);
      }
      $didold++;
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, \@labels, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
    delete $Self->{backfilling};
  }

  if ($res->{update}) {
    my $changed = $res->{update}[1];
    foreach my $uid (sort { $a <=> $b } keys %$changed) {
      my @labels = ($forcelabel);
      if ($Self->{is_gmail}) {
        @labels = $forcelabel ? ($forcelabel) : @{$changed->{$uid}{"x-gm-labels"}};
      }
      $Self->changed_record($ifolderid, $uid, $changed->{$uid}{'flags'}, \@labels);
    }
  }

  if ($res->{new}) {
    my $new = $res->{new}[1];
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid, @labels);
      if ($Self->{is_gmail}) {
        ($msgid, $thrid) = ($new->{$uid}{"x-gm-msgid"}, $new->{$uid}{"x-gm-thrid"});
        @labels = $forcelabel ? ($forcelabel) : @{$new->{$uid}{"x-gm-labels"}};
      }
      else {
        ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
        @labels = ($forcelabel);
      }
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, \@labels, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  $Self->dupdate('ifolders', {highestmodseq => $res->{newstate}{highestmodseq}, uidfirst => $uidfirst, uidnext => $res->{newstate}{uidnext}}, {ifolderid => $ifolderid});

  $Self->commit();

  return $didold if $batchsize;

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
}

sub imap_search {
  my $Self = shift;
  my @search = @_;

  my $dbh = $Self->dbh();
  my $data = $dbh->selectall_arrayref("SELECT * FROM ifolders", {Slice => {}});

  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }

  my %matches;
  foreach my $item (@$data) {
    my $from = $item->{uidfirst};
    my $to = $item->{uidnext}-1;
    my $res = $Self->backend_cmd('imap_search', $item->{imapname}, 'uid', "$from:$to", @search);
    # XXX - uidvaldity changed
    next unless $res->[2] == $item->{uidvalidity};
    foreach my $uid (@{$res->[3]}) {
      my ($msgid) = $dbh->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? and uid = ?", {}, $item->{ifolderid}, $uid);
      $matches{$msgid} = 1;
    }
  }

  return \%matches;
}

sub changed_record {
  my $Self = shift;
  my ($folder, $uid, $flaglist, $labellist) = @_;

  my $flags = encode_json([grep { lc $_ ne '\\recent' } sort @$flaglist]);
  my $labels = encode_json([sort @$labellist]);

  my ($msgid) = $Self->{dbh}->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $folder, $uid);

  $Self->dmaybeupdate('imessages', {flags => $flags, labels => $labels}, {ifolderid => $folder, uid => $uid});

  $Self->apply_data($msgid, $flaglist, $labellist);
}

sub import_message {
  my $Self = shift;
  my $rfc822 = shift;
  my $mailboxIds = shift;
  my %flags = @_;

  my $dbh = $Self->dbh();
  my $folderdata = $dbh->selectall_arrayref("SELECT * FROM ifolders", {Slice => {}});
  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;

  # store to the first named folder - we can use labels on gmail to add to other folders later.
  my ($id, @others) = @$mailboxIds;
  my $imapname = $jmailmap{$id}{imapname};

  my @flags;
  push @flags, "\\Seen" unless $flags{isUnread};
  push @flags, "\\Answered" if $flags{isAnswered};
  push @flags, "\\Flagged" if $flags{isFlagged};
  push @flags, "\\Draft" if $flags{isDraft};

  my $internaldate = time(); # XXX - allow setting?
  my $date = Date::Format::time2str('%e-%b-%Y %T %z', $internaldate);

  my $data = $Self->backend_cmd('imap_append', $imapname, "(@flags)", $date, $rfc822);
  # XXX - compare $data->[2] with uidvalidity
  my $uid = $data->[3];

  # make sure we're up to date: XXX - imap only
  if ($Self->{is_gmail}) {
    my ($am) = grep { lc $_->{label} eq '\\allmail' } @$folderdata;
    $Self->do_folder($am->{ifolderid}, undef);
  }
  else {
    my $fdata = $jmailmap{$mailboxIds->[0]};
    $Self->do_folder($fdata->{ifolderid}, $fdata->{label});
  }

  my ($msgid, $thrid) = $Self->dbh->selectrow_array("SELECT msgid, thrid FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $jmailmap{$id}{ifolderid}, $uid);

  # save us having to download it again
  my $eml = Email::MIME->new($rfc822);
  my $message = $Self->parse_message($msgid, $eml);

  $Self->begin();
  $Self->dinsert('jrawmessage', {
    msgid => $msgid,
    parsed => encode_json($message),
    hasAttachment => $message->{hasAttachment},
  });
  $Self->commit();

  return ($msgid, $thrid);
}

sub update_messages {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

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

  my $folderdata = $dbh->selectall_arrayref("SELECT * FROM ifolders", {Slice => {}});
  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;
  my $jmapdata = $dbh->selectall_arrayref("SELECT * FROM jmailboxes", {Slice => {}});
  my %jidmap = map { $_->{jmailboxid} => $_->{role} } @$jmapdata;
  my %jrolemap = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$jmapdata;

  my @changed;
  foreach my $ifolderid (keys %updatemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}{imapname};
    my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};

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
        # jmailboxid
        my @mboxes = map { $idmap->($_) } @{$action->{mailboxIds}};
        my ($has_outbox) = grep { $jidmap{$_} eq 'outbox' } @mboxes;
        my (@others) = grep { $jidmap{$_} ne 'outbox' } @mboxes;
        if ($has_outbox) {
          # move to sent when we're done
          push @others, $jmailmap{$jrolemap{'sent'}}{jmailboxid};
          my ($type, $rfc822) = $Self->get_raw_message($msgid);
          # XXX - add attachments - we might actually want the parsed message and then realise the attachments...
          $Self->backend_cmd('send_email', $rfc822);

          # strip the \Draft flag
          $Self->backend_cmd('imap_update', $imapname, $uidvalidity, $uid, 0, ["\\Draft"]);

          # add the \Answered flag to our in-reply-to
          my ($updateid) = $dbh->selectrow_array("SELECT msginreplyto FROM jmessages WHERE msgid = ?", {}, $msgid);
          goto done unless $updateid;
          my ($updatemsgid) = $dbh->selectrow_array("SELECT msgid FROM jmessages WHERE msgmessageid = ?", {}, $updateid);
          goto done unless $updatemsgid;
          my ($ifolderid, $updateuid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $updatemsgid);
          goto done unless $ifolderid;
          my $updatename = $foldermap{$ifolderid}{imapname};
          my $updatevalidity = $foldermap{$ifolderid}{uidvalidity};
          goto done unless $updatename;
          $Self->backend_cmd('imap_update', $updatename, $updatevalidity, $updateuid, 1, ["\\Answered"]);
        }
        done:
        if ($Self->{is_gmail}) {
          # because 'archive' is synthetic on gmail we strip it here
          (@others) = grep { $jidmap{$_} ne 'archive' } @others;
          my @labels = grep { $_ and lc $_ ne '\\allmail' } map { $jmailmap{$_}{label} } @others;
          $Self->backend_cmd('imap_labels', $imapname, $uidvalidity, $uid, \@labels);
        }
        else {
          my $id = $others[0];
          my $newfolder = $jmailmap{$id}{imapname};
          $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uid, $newfolder);
        }
      }
      # XXX - handle errors from backend commands
      push @changed, $msgid;
    }
  }

  return (\@changed, \%notchanged);
}

sub destroy_messages {
  my $Self = shift;
  my $ids = shift;

  my $dbh = $Self->{dbh};

  my %destroymap;
  my %notdestroyed;
  foreach my $msgid (@$ids) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    if ($ifolderid and $uid) {
      $destroymap{$ifolderid}{$uid} = $msgid;
    }
    else {
      $notdestroyed{$msgid} = "No such message on server";
    }
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, uidvalidity, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[4] => $_ } grep { $_->[4] } @$folderdata;

  my @destroyed;
  foreach my $ifolderid (keys %destroymap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    my $uidvalidity = $foldermap{$ifolderid}[2];
    unless ($imapname) {
      $notdestroyed{$_} = "No folder" for values %{$destroymap{$ifolderid}};
    }
    my $uids = [sort keys %{$destroymap{$ifolderid}}];
    $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uids, undef); # no destination folder
    push @destroyed, values %{$destroymap{$ifolderid}};
  }
  return (\@destroyed, \%notdestroyed);
}

sub deleted_record {
  my $Self = shift;
  my ($folder, $uid) = @_;

  my ($msgid, $jmailboxid) = $Self->{dbh}->selectrow_array("SELECT msgid, jmailboxid FROM imessages JOIN ifolders USING (ifolderid) WHERE imessages.ifolderid = ? AND uid = ?", {}, $folder, $uid);
  return unless $msgid;

  $Self->ddelete('imessages', {ifolderid => $folder, uid => $uid});

  $Self->ddirty('jmessages', {}, {msgid => $msgid}); # bump modeseq
  $Self->delete_message_from_mailbox($msgid, $jmailboxid);
}

sub new_record {
  my $Self = shift;
  my ($ifolderid, $uid, $flaglist, $labellist, $envelope, $internaldate, $msgid, $thrid, $size) = @_;

  my $flags = encode_json([grep { lc $_ ne '\\recent' } sort @$flaglist]);
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
  my @list = @$labellist;
  # gmail empty list means archive at our end
  my @jmailboxids = grep { $_ } map { $labels->{$_}[1] } @list;

  # check for archive folder for gmail
  if ($Self->{is_gmail} and not @list) {
    @jmailboxids = $Self->{dbh}->selectrow_array("SELECT jmailboxid FROM jmailboxes WHERE role = 'archive'");
  }

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
  my $envelope = decode_json($data || "{}");
  my $encsub = Encode::decode('MIME-Header', $envelope->{Subject});
  return (
    msgsubject => $encsub,
    msgfrom => $envelope->{From},
    msgto => $envelope->{To},
    msgcc => $envelope->{Cc},
    msgbcc => $envelope->{Bcc},
    msgdate => str2time($envelope->{Date}),
    msginreplyto => _trimh($envelope->{'In-Reply-To'}),
    msgmessageid => _trimh($envelope->{'Message-ID'}),
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
    my %parsed;
    foreach my $uid (keys %{$res->{data}}) {
      my $rfc822 = $res->{data}{$uid};
      next unless $rfc822;
      my $msgid = $uhash->{$uid};
      next if $result{$msgid};
      my $eml = Email::MIME->new($rfc822);
      $parsed{$msgid} = $Self->parse_message($msgid, $eml);
    }

    $Self->begin();
    foreach my $msgid (sort keys %parsed) {
      my $message = $parsed{$msgid};
      $Self->dinsert('jrawmessage', {
       msgid => $msgid,
       parsed => encode_json($message),
       hasAttachment => $message->{hasAttachment},
      });
      $result{$msgid} = $parsed{$msgid};
    }
    $Self->commit();
  }

  # XXX - handle not getting data that we need?
  my @stillneed = grep { not $result{$_} } @ids;

  return \%result;
}

sub find_type {
  my $message = shift;
  my $part = shift;

  return $message->{type} if ($message->{id} || '') eq $part;

  foreach my $sub (@{$message->{attachments}}) {
    my $type = find_type($sub, $part);
    return $type if $type;
  }
}

sub get_raw_message {
  my $Self = shift;
  my $msgid = shift;
  my $part = shift;

  my ($imapname, $uidvalidity, $uid) = $Self->dbh->selectrow_array("SELECT imapname, uidvalidity, uid FROM ifolders JOIN imessages USING (ifolderid) WHERE msgid = ?", {}, $msgid);
  return unless $imapname;

  my $type = 'message/rfc822';
  if ($part) {
    my $parsed = $Self->fill_messages($msgid);
    $type = find_type($parsed->{$msgid}, $part);
  }

  my $res = $Self->backend_cmd('imap_getpart', $imapname, $uidvalidity, $uid, $part);

  return ($type, $res->{data});
}

sub create_mailboxes {
  my $Self = shift;
  my $new = shift;

  my $dbh = $Self->{dbh};

  my %idmap;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $mailbox = $new->{$cid};

    my $imapname = $mailbox->{name};
    if ($mailbox->{parentId}) {
      my ($parentName, $sep) = $dbh->selectrow_array("SELECT imapname, sep FROM ifolders WHERE jmailboxid = ?", {}, $mailbox->{parentId});
      # XXX - errors
      $imapname = "$parentName$sep$imapname";
    }
    else {
      my ($prefix) = $dbh->selectrow_array("SELECT imapPrefix FROM iserver");
      $imapname = "$prefix$imapname";
    }

    my $res = $Self->backend_cmd('create_mailbox', $imapname);
    # XXX - handle errors...
    $idmap{$imapname} = $cid; # need to resolve this after the sync
  }

  # (in theory we could save this until the end and resolve the names in after the renames and deletes... but it does mean
  # we can't use ids as referenes...)
  $Self->sync_folders() if keys %idmap;

  my %createmap;
  foreach my $imapname (keys %idmap) {
    my $cid = $idmap{$imapname};
    my ($jid) = $dbh->selectrow_array("SELECT jmailboxid FROM ifolders WHERE imapname = ?", {}, $imapname);
    $createmap{$cid} = $jid;
  }

  return (\%createmap, \%notcreated);
}

sub update_mailboxes {
  my $Self = shift;
  my $update = shift;
  my $idmap = shift;

  my $dbh = $Self->{dbh};

  my @updated;
  my %notupdated;
  # XXX - reorder the crap out of this if renaming multiple mailboxes due to deep rename
  foreach my $id (keys %$update) {
    my $mailbox = $update->{$id};
    my $imapname = $mailbox->{name};
    next unless (defined $imapname and $imapname ne '');
    my $parentId = $mailbox->{parentId};
    ($parentId) = $dbh->selectrow_array("SELECT parentId FROM jmailboxes WHERE jmailboxid = ?", {}, $id)
      unless exists $mailbox->{parentId};
    if ($parentId) {
      $parentId = $idmap->($parentId);
      my ($parentName, $sep) = $dbh->selectrow_array("SELECT imapname, sep FROM ifolders WHERE jmailboxid = ?", {}, $parentId);
      # XXX - errors
      $imapname = "$parentName$sep$imapname";
    }
    else {
      my ($prefix) = $dbh->selectrow_array("SELECT imapPrefix FROM iserver");
      $prefix = '' unless $prefix;
      $imapname = "$prefix$imapname";
    }

    my ($oldname) = $dbh->selectrow_array("SELECT imapname FROM ifolders WHERE jmailboxid = ?", {}, $id);

    $Self->backend_cmd('rename_mailbox', $oldname, $imapname) if $oldname ne $imapname;
    push @updated, $id;
  }

  $Self->sync_folders() if @updated;

  return (\@updated, \%notupdated);
}

sub destroy_mailboxes {
  my $Self = shift;
  my $destroy = shift;

  my $dbh = $Self->{dbh};

  my @destroyed;
  my %notdestroyed;
  foreach my $id (@$destroy) {
    my ($oldname) = $dbh->selectrow_array("SELECT imapname FROM ifolders WHERE jmailboxid = ?", {}, $id);

    $Self->backend_cmd('delete_mailbox', $oldname);
    push @destroyed, $id;
  }

  $Self->sync_folders() if @destroyed;

  return (\@destroyed, \%notdestroyed);
}

sub create_calendar_events {
  my $Self = shift;
  my $new = shift;

  my $dbh = $Self->{dbh};

  my %createmap;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $calendar = $new->{$cid};
    my ($href) = $dbh->selectrow_array("SELECT href FROM icalendars WHERE icalendarid = ?", {}, $calendar->{calendarId});
    unless ($href) {
      $notcreated{$cid} = "No such calendar on server";
      next;
    }
    my $uid = new_uuid_string();

    $Self->backend_cmd('new_event', $href, {%$calendar, uid => $uid});
    $createmap{$cid} = { id => $uid };
  }

  return (\%createmap, \%notcreated);
}

sub update_calendar_events {
  my $Self = shift;
  my $update = shift;
  my $idmap = shift;

  my $dbh = $Self->{dbh};

  my @updated;
  my %notupdated;
  foreach my $uid (keys %$update) {
    my $calendar = $update->{$uid};
    my ($resource) = $dbh->selectrow_array("SELECT resource FROM ievents WHERE uid = ?", {}, $uid);
    unless ($resource) {
      $notupdated{$uid} = "No such event on server";
      next;
    }

    $Self->backend_cmd('update_event', $resource, $calendar);
    push @updated, $uid;
  }

  return (\@updated, \%notupdated);
}

sub destroy_calendar_events {
  my $Self = shift;
  my $destroy = shift;

  my $dbh = $Self->{dbh};

  my @destroyed;
  my %notdestroyed;
  foreach my $uid (@$destroy) {
    my ($resource) = $dbh->selectrow_array("SELECT resource FROM ievents WHERE uid = ?", {}, $uid);
    unless ($resource) {
      $notdestroyed{$uid} = "No such event on server";
      next;
    }

    $Self->backend_cmd('delete_event', $resource);
    push @destroyed, $uid;
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_contact_groups {
  my $Self = shift;
  my $new = shift;

  my $dbh = $Self->{dbh};

  my %createmap;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $contact = $new->{$cid};
    #my ($href) = $dbh->selectrow_array("SELECT href FROM iaddressbooks WHERE iaddressbookid = ?", {}, $contact->{addressbookId});
    my ($href) = $dbh->selectrow_array("SELECT href FROM iaddressbooks");
    unless ($href) {
      $notcreated{$cid} = "No such addressbook on server";
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new();
    my $uid = new_uuid_string();
    $card->uid($uid);
    $card->VKind('group');
    $card->VFN($contact->{name}) if exists $contact->{name};
    if (exists $contact->{contactIds}) {
      my @ids = @{$contact->{contactIds}};
      $card->VGroupContactUIDs(\@ids);
    }

    $Self->backend_cmd('new_card', $href, $card);
    $createmap{$cid} = { id => $uid };
  }

  return (\%createmap, \%notcreated);
}

sub update_contact_groups {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  my $dbh = $Self->{dbh};

  my @updated;
  my %notchanged;
  foreach my $carduid (keys %$changes) {
    my $contact = $changes->{$carduid};
    my ($resource, $content) = $dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notchanged{$carduid} = "No such card on server";
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new_fromstring($content);
    $card->VKind('group');
    $card->VFN($contact->{name}) if exists $contact->{name};
    if (exists $contact->{contactIds}) {
      my @ids = map { $idmap->($_) } @{$contact->{contactIds}};
      $card->VGroupContactUIDs(\@ids);
    }

    $Self->backend_cmd('update_card', $resource, $card);
    push @updated, $carduid;
  }

  return (\@updated, \%notchanged);
}

sub destroy_contact_groups {
  my $Self = shift;
  my $destroy = shift;

  my $dbh = $Self->{dbh};

  my @destroyed;
  my %notdestroyed;
  foreach my $carduid (@$destroy) {
    my ($resource, $content) = $dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notdestroyed{$carduid} = "No such card on server";
      next;
    }
    $Self->backend_cmd('delete_card', $resource);
    push @destroyed, $carduid;
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_contacts {
  my $Self = shift;
  my $new = shift;

  my $dbh = $Self->{dbh};

  my %createmap;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $contact = $new->{$cid};
    my ($href) = $dbh->selectrow_array("SELECT href FROM iaddressbooks");
    unless ($href) {
      $notcreated{$cid} = "No such addressbook on server";
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new();
    my $uid = new_uuid_string();
    $card->uid($uid);
    $card->VLastName($contact->{lastName}) if exists $contact->{lastName};
    $card->VFirstName($contact->{firstName}) if exists $contact->{firstName};
    $card->VTitle($contact->{prefix}) if exists $contact->{prefix};

    $card->VCompany($contact->{company}) if exists $contact->{company};
    $card->VDepartment($contact->{department}) if exists $contact->{department};

    $card->VEmails(@{$contact->{emails}}) if exists $contact->{emails};
    $card->VAddresses(@{$contact->{addresses}}) if exists $contact->{addresses};
    $card->VPhones(@{$contact->{phones}}) if exists $contact->{phones};
    $card->VOnline(@{$contact->{online}}) if exists $contact->{online};

    $card->VNickname($contact->{nickname}) if exists $contact->{nickname};
    $card->VBirthday($contact->{birthday}) if exists $contact->{birthday};
    $card->VNotes($contact->{notes}) if exists $contact->{notes};

    $Self->backend_cmd('new_card', $href, $card);
    $createmap{$cid} = { id => $uid };
  }

  return (\%createmap, \%notcreated);
}

sub update_contacts {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  my $dbh = $Self->{dbh};

  my @updated;
  my %notchanged;
  foreach my $carduid (keys %$changes) {
    my $contact = $changes->{$carduid};
    my ($resource, $content) = $dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notchanged{$carduid} = "No such card on server";
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new_fromstring($content);
    $card->VLastName($contact->{lastName}) if exists $contact->{lastName};
    $card->VFirstName($contact->{firstName}) if exists $contact->{firstName};
    $card->VTitle($contact->{prefix}) if exists $contact->{prefix};

    $card->VCompany($contact->{company}) if exists $contact->{company};
    $card->VDepartment($contact->{department}) if exists $contact->{department};

    $card->VEmails(@{$contact->{emails}}) if exists $contact->{emails};
    $card->VAddresses(@{$contact->{addresses}}) if exists $contact->{addresses};
    $card->VPhones(@{$contact->{phones}}) if exists $contact->{phones};
    $card->VOnline(@{$contact->{online}}) if exists $contact->{online};

    $card->VNickname($contact->{nickname}) if exists $contact->{nickname};
    $card->VBirthday($contact->{birthday}) if exists $contact->{birthday};
    $card->VNotes($contact->{notes}) if exists $contact->{notes};

    $Self->backend_cmd('update_card', $resource, $card);
    push @updated, $carduid;
  }

  return (\@updated, \%notchanged);
}

sub destroy_contacts {
  my $Self = shift;
  my $destroy = shift;

  my $dbh = $Self->{dbh};

  my @destroyed;
  my %notdestroyed;
  foreach my $carduid (@$destroy) {
    my ($resource, $content) = $dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notdestroyed{$carduid} = "No such card on server";
      next;
    }
    $Self->backend_cmd('delete_card', $resource);
    push @destroyed, $carduid;
  }

  return (\@destroyed, \%notdestroyed);
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
  imapHost TEXT,
  imapPort INTEGER,
  imapSSL INTEGER,
  imapPrefix TEXT,
  smtpHost TEXT,
  smtpPort INTEGER,
  smtpSSL INTEGER,
  caldavURL TEXT,
  carddavURL TEXT,
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

# not used for Gmail, but it doesn't hurt to have it
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
  sortOrder INTEGER,
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
  uid TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ieventuid ON ievents (uid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iaddressbooks (
  iaddressbookid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  sortOrder INTEGER,
  syncToken TEXT,
  jaddressbookid INTEGER,
  mtime DATE NOT NULL
);
EOF

# XXX - should we store 'kind' in this?  Means we know which j table to update
# if someone reuses a UID from a contact to a group or vice versa...
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icards (
  icardid INTEGER PRIMARY KEY NOT NULL,
  iaddressbookid INTEGER,
  resource TEXT,
  uid TEXT,
  kind TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS icarduid ON icards (uid)");

}

1;
