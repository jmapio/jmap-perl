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

our $TAG = 1;

# XXX - specialuse, this is just for iCloud for now
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
  unless ($Self->{backend}) {
    my $w = AnyEvent->condvar;
    my $auth = $Self->access_token();
    tcp_connect('localhost', 5005, sub {
      my $fh = shift;
      my $handle = AnyEvent::Handle->new(fh => $fh);
      $handle->push_write(json => {hostname => $auth->[0], username => $auth->[1], password => $auth->[2]});
      $handle->push_write("\012");
      $handle->push_read(json => sub {
        my $hdl = shift;
        my $json = shift;
        die "Failed to setup " . Dumper($json) unless $json->[0] eq 'setup';
        $w->send($handle);
      });
    });
    $Self->{backend} = $w->recv;
  }
  my $handle = $Self->{backend};
  my $w = AnyEvent->condvar;
  my $tag = "T" . $TAG++;
  $handle->push_write(json => [$cmd, \@args, $tag]); # whatever
  $handle->push_write("\012");
  $handle->push_read(json => sub {
    my $hdl = shift;
    my $json = shift;
    die "INVALID RESPONSE" unless $json->[2] eq $tag;
    $w->send($json->[1]);
  });
  my $res = $w->recv;

  warn Dumper ($cmd, \@args, $res);

  return $res;
}

# synchronise list from IMAP server to local folder cache
# call in transaction
sub sync_folders {
  my $Self = shift;

  my $dbh = $Self->dbh();

  my $folders = $Self->backend_cmd('folders', []);
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

  if (keys %getstatus) {
    my $data = $Self->backend_cmd('imap_status', [keys %getstatus]);
    foreach my $name (keys %$data) {
      my $status = $data->{$name};
      $Self->dmaybeupdate('ifolders', {
        uidvalidity => $status->{uidvalidity},
        uidnext => $status->{uidnext},
        uidfirst => $status->{uidnext},
        highestmodseq => $status->{highestmodseq},
      }, {ifolderid => $getstatus{$name}});
    }
  }

  foreach my $folder (@$ifolders) {
    my $id = $folder->[0];
    next if $seen{$id};
    $dbh->do("DELETE FROM ifolders WHERE ifolderid = ?", {}, $id);
  }

  $Self->sync_jmailboxes();
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jmailboxes {
  my $Self = shift;
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
    warn " MAPPING $fname ($folder->[1])";
    $fname =~ s/^INBOX\.//;
    # check for roles first
    my @bits = split "[$folder->[1]]", $fname;
    my $role = $ROLE_MAP{lc $fname};
    my $id = 0;
    my $parentid = 0;
    my $name;
    my $precedence = 3;
    $precedence = 2 if $role;
    $precedence = 1 if ($role||'') eq 'inbox';
    while (my $item = shift @bits) {
      $seen{$id} = 1 if $id;
      $name = $item;
      $parentid = $id;
      $id = $byname{$parentid}{$name};
      unless ($id) {
        if (@bits) {
          # need to create intermediate folder ...
          # XXX  - label noselect?
          $id = $Self->dmake('jmailboxes', {name => $name, precedence => 4, parentid => $parentid});
          $byname{$parentid}{$name} = $id;
        }
      }
    }
    next unless $name;
    my %details = (
      name => $name,
      parentid => $parentid,
      precedence => $precedence,
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
}

# synchronise list from CalDAV server to local folder cache
# call in transaction
sub sync_calendars {
  my $Self = shift;

  my $dbh = $Self->dbh();

  my $calendars = $Self->backend_cmd('calendars', []);
  my $icalendars = $dbh->selectall_arrayref("SELECT icalendarid, href, name, isReadOnly, colour FROM icalendars");
  my %byhref = map { $_->[1] => $_ } @$icalendars;

  foreach my $calendar (@$calendars) {
    my $id = $byhref{$calendar->{href}}[0];
    my $data = {isReadOnly => $calendar->{isReadOnly}, href => $calendar->{href},
                colour => $calendar->{colour}, name => $calendar->{name}};
    if ($id) {
      $Self->dmaybeupdate('icalendars', $data, {icalendarid => $id});
    }
    else {
      $id = $Self->dinsert('icalendars', $data);
    }
    $seen{$id} = 1;
  }

  foreach my $calendar (@$icalendars) {
    my $id = $calendar->[0];
    next if $seen{$id};
    $dbh->do("DELETE FROM icalendars WHERE icalendarid = ?", {}, $id);
  }

  $Self->sync_jcalendars();
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jcalendars {
  my $Self = shift;
  my $dbh = $Self->dbh();
  my $icalendars = $dbh->selectall_arrayref("SELECT icalendarid, name, colour, jcalendarid FROM icalendars");
  my $jcalendars = $dbh->selectall_arrayref("SELECT jcalendarid, name, colour, active FROM jcalendars");

  my %jbyid;
  foreach my $calendar (@$jcalendars) {
    $jbyid{$calendar->[0]} = $calendar;
  }

  my %seen;
  foreach my $calendar (@$icalendars) {
    if ($jbyid{$calendar->[3]}) {
      $Self->dmaybeupdate('jcalendars', {name => $calendar->[1], colour => $calendar->[2]}, {jcalendarid => $calendar->[3]});
      $seen{$calendar->[3]} = 1;
    }
    else {
      my $id = $Self->dinsert('jcalendars', {name => $calendar->[1], colour => $calendar->[2]});
      $seen{$id} = 1;
    }
  }

  foreach my $calendar (@$jcalendars) {
    my $id = $calendar->[0];
    next if $seen{$id};
    $Self->dupdate('jcalendars', {active => 0}, {jcalendarid => $id});
  }
}

sub labels {
  my $Self = shift;
  unless ($Self->{t}{labels}) {
    my $data = $Self->dbh->selectall_arrayref("SELECT label, ifolderid, jmailboxid, imapname FROM ifolders");
    $Self->{t}{labels} = { map { lc $_->[0] => [$_->[1], $_->[2], $_->[3]] } @$data };
  }
  return $Self->{t}{labels};
}

sub sync {
  my $Self = shift;
  my $data = $Self->dbh->selectall_arrayref("SELECT ifolderid,label FROM ifolders");

  foreach my $row (@$data) {
    $Self->do_folder(@$row);
  }
}

sub backfill {
  my $Self = shift;
  my $data = $Self->dbh->selectall_arrayref("SELECT ifolderid,label FROM ifolders WHERE uidnext > 1 AND uidfirst > 1 ORDER BY mtime");
  my $rest = 500;
  foreach my $row (@$data) {
    $rest -= $Self->do_folder(@$row, $rest);
    last if $rest < 10;
  }
}

sub firstsync {
  my $Self = shift;

  $Self->sync_folders();
  $Self->sync_calendars();
  $Self->sync_addressbooks();

  my $labels = $Self->labels();

  my $ifolderid = $labels->{"inbox"}[0];
  $Self->do_folder($ifolderid, "inbox", 50);

  my $msgids = $Self->dbh->selectcol_arrayref("SELECT msgid FROM imessages WHERE ifolderid = ? ORDER BY uid DESC LIMIT 50", {}, $ifolderid);

  # pre-load the INBOX!
  $Self->fill_messages(@$msgids);
}

sub calcmsgid {
  my $Self = shift;
  my $envelope = shift;
  my $json = JSON::XS->new->allow_nonref->canonical;
  my $coded = $json->encode($envelope);
  my $msgid = sha1_hex($coded);

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
  my $imap = $Self->{imap};
  my $dbh = $Self->dbh();

  my ($imapname, $uidfirst, $uidnext, $uidvalidity, $highestmodseq) =
     $dbh->selectrow_array("SELECT imapname, uidfirst, uidnext, uidvalidity, highestmodseq FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
  die "NO SUCH FOLDER $ifolderid" unless $imapname;

  my %fetches;
  $fetches{new} = [$uidnext, '*', [qw(internaldate envelope rfc822.size)]];
  $fetches{update} = [$uidfirst, $uidnext - 1, [], $highestmodseq];

  if ($uidfirst > 1 and $batchsize) {
    my $end = $uidfirst - 1;
    $uidfirst -= $batchsize;
    $uidfirst = 1 if $uidfirst < 1;
    $fetches{backfill} = [$uidfirst, $end, [qw(internaldate envelope rfc822.size)]];
  }

  my $res = $Self->backend_cmd('imap_fetch', $imapname, {
    uidvalidity => $uidvalidity,
    highestmodseq => $highestmodseq,
    uidnext => $uidnext,
  },\%fetches);

  if ($res->{newstate}{uidvalidity} != $uidvalidity) {
    # going to want to nuke everything for the existing folder and create this - but for now, just die
    die "UIDVALIDITY CHANGED $imapname: $uidvalidity => $res->{newstate}{uidvalidity}";
  }

  my $didold = 0;
  if ($res->{backfill}) {
    my $new = $res->{backfill}[1];
    $Self->{backfilling} = 1;
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($new->{$uid}{envelope});
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
      my ($msgid, $thrid) = $Self->calcmsgid($new->{$uid}{envelope});
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, [$forcelabel], $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  # need to make changes before counting
  if ($uidfirst == 1) {
    my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
    if ($count != $res->{newstate}{exists}) {
      my $to = $uidnext - 1;
      $Self->log('debug', "COUNTING $imapname: $uidfirst:$to (something deleted)");
      my $res = $Self->backend_cmd('imap_count', $imapname, $uidvalidity, "$uidfirst:$to");
      my $uids = $res->{data};
      my $data = $dbh->selectcol_arrayref("SELECT uid FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
      my %exists = map { $_ => 1 } @$uids;
      foreach my $uid (@$data) {
        next if $exists{$uid};
        $Self->deleted_record($ifolderid, $uid);
      }
    }
  }

  $Self->dupdate('ifolders', {highestmodseq => $res->{newstate}{highestmodseq}, uidfirst => $uidfirst, uidnext => $res->{newstate}{uidnext}}, {ifolderid => $ifolderid});

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
  foreach my $msgid (keys %$changes) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    $updatemap{$ifolderid}{$uid} = $changes->{$msgid};
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, uidvalidity, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[4] => $_ } @$folderdata;

  foreach my $ifolderid (keys %updatemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    my $uidvalidity = $foldermap{$ifolderid}[2];
    die "NO SUCH FOLDER $ifolderid" unless $imapname;

    foreach my $uid (sort keys %{$updatemap{$ifolderid}}) {
      my $action = $updatemap{$ifolderid}{$uid};
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
    }
  }
}

sub delete_messages {
  my $Self = shift;
  my $ids = shift;

  my $dbh = $Self->{dbh};

  my %deletemap;
  foreach my $msgid (@$ids) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    $deletemap{$ifolderid}{$uid} = 1;
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, uidvalidity, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[4] => $_ } grep { $_->[4] } @$folderdata;

  foreach my $ifolderid (keys %deletemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    my $uidvalidity = $foldermap{$ifolderid}[2];
    die "NO SUCH FOLDER $ifolderid" unless $imapname;

    my $uids = [sort keys %{$deletemap{$ifolderid}}];

    $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uids, undef); # no destination folder
  }
}

sub deleted_record {
  my $Self = shift;
  my ($folder, $uid) = @_;

  my ($msgid) = $Self->{dbh}->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $folder, $uid);

  $Self->ddelete('imessages', {ifolderid => $folder, uid => $uid});

  $Self->apply_data($msgid, [], []);
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
    my ($imapname, $uidvalidity) = $Self->dbh->selectrow_array("SELECT imapname, uidvalidity FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
    my $uhash = $udata{$ifolderid};

    my $uids = join(',', sort { $a <=> $b } keys %$uhash);
    my $res = $Self->backend_cmd('imap_fill', $imapname, $uidvalidity, $uids);

    foreach my $uid (keys %{$res->{data}}) {
      warn "FETCHED BODY FOR $uid\n";
      my $rfc822 = $res->{data}{$uid};
      my $msgid = $uhash->{$uid};
      $result{$msgid} = $Self->add_raw_message($msgid, $rfc822);
    }
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
  colour TEXT,
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
CREATE TABLE IF NOT EXISTS iabooks (
  iabookid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  syncToken TEXT,
  jabookid INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icontacts (
  icontactid INTEGER PRIMARY KEY NOT NULL,
  iabookid INTEGER,
  resource TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

}

1;
