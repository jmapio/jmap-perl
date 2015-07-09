#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::ImapDB;
use base qw(JMAP::DB);

use DBI;
use Mail::IMAPTalk;
use Date::Parse;
use JSON::XS qw(encode_json decode_json);
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Encode;
use Encode::MIME::Header;
use Digest::SHA qw(sha1_hex);

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
);

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
  }
}

sub setuser {
  my $Self = shift;
  my ($hostname, $username, $password) = @_;
  my $data = $Self->dbh->selectrow_arrayref("SELECT hostname, username, password FROM iserver");
  if ($data and $data->[0]) {
    $Self->dmaybeupdate('iserver', {hostname => $hostname, username => $username, password => $password});
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
    $Self->dmaybeupdate('account', {email => $username});
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

sub connect {
  my $Self = shift;

  if ($Self->{imap}) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  for (1..3) {
    $Self->log('debug', "Looking for server for $Self->{accountid}");
    my $data = $Self->dbh->selectrow_arrayref("SELECT hostname, username, password, lastfoldersync FROM iserver");
    die "UNKNOWN SERVER for $Self->{accountid}" unless ($data and $data->[0]);
    my $port = 993;
    my $usessl = $port != 143;  # we use SSL for anything except default
    $Self->log('debug', "getting imaptalk\n");
    $Self->{imap} = Mail::IMAPTalk->new(
      Server   => $data->[0],
      Port     => $port,
      Username => $data->[1],
      Password => $data->[2],
      # not configurable right now...
      UseSSL   => $usessl,
      UseBlocking => $usessl,
    );
    next unless $Self->{imap};
    $Self->log('debug', "Connected to $data->[0] as $data->[1]");
    eval { $Self->{imap}->enable('condstore') };
    $Self->begin();
    $Self->sync_folders();
    $Self->dmaybeupdate('iserver', {lastfoldersync => time()}, {username => $data->[0]});
    $Self->commit();
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  die "Could not connect to IMAP server: $@";
}

# synchronise list from IMAP server to local folder cache
# call in transaction
sub sync_folders {
  my $Self = shift;

  my $dbh = $Self->dbh();
  my $imap = $Self->{imap};

  my @folders = $imap->list('', '*');
  my $ifolders = $dbh->selectall_arrayref("SELECT ifolderid, sep, imapname, label FROM ifolders");
  my %ibylabel = map { $_->[3] => $_ } @$ifolders;
  my %seen;

  foreach my $folder (@folders) {
    my $role = $ROLE_MAP{lc $folder->[2]};
    my $label = $role || $folder->[2];
    my $id = $ibylabel{$label}[0];
    if ($id) {
      $Self->dmaybeupdate('ifolders', {sep => $folder->[1], imapname => $folder->[2]}, {ifolderid => $id});
    }
    else {
      $id = $Self->dinsert('ifolders', {sep => $folder->[1], imapname => $folder->[2], label => $label});
    }
    $seen{$id} = 1;
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
      if (@bits) {
        $seen{$id} = 1;
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
  my $imap = $Self->{imap};
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
  my $imap = $Self->{imap};
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

  my ($imapname, $olduidfirst, $olduidnext, $olduidvalidity, $oldhighestmodseq) = $dbh->selectrow_array("SELECT imapname, uidfirst, uidnext, uidvalidity, highestmodseq FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
  die "NO SUCH FOLDER $ifolderid" unless $imapname;
  $olduidfirst ||= 0;

  my $r = $imap->examine($imapname);

  my $uidvalidity = $imap->get_response_code('uidvalidity');
  my $uidnext = $imap->get_response_code('uidnext');
  my $highestmodseq = $imap->get_response_code('highestmodseq') || 0;
  my $exists = $imap->get_response_code('exists') || 0;

  if ($olduidvalidity and $olduidvalidity != $uidvalidity) {
    $oldhighestmodseq = 0;
    $olduidfirst = 0;
    $olduidnext = 1;
    # XXX - delete all the data for this folder and re-sync it
  }
  elsif ($olduidfirst == 1 and $oldhighestmodseq and $highestmodseq == $oldhighestmodseq) {
    $Self->log('debug', "Nothing to do for $imapname at $highestmodseq");
    return 0; # yay, nothing to do
  }

  $olduidfirst = $uidnext unless $olduidfirst;
  $olduidnext = $uidnext unless $olduidnext;

  my $uidfirst = $olduidfirst;
  my $didold = 0;
  if ($olduidfirst > 1 and $batchsize) {
    $uidfirst = $olduidfirst - $batchsize;
    $uidfirst = 1 if $uidfirst < 1;
    my $to = $olduidfirst - 1;
    $Self->log('debug', "FETCHING $imapname: $uidfirst:$to");
    my $new = $imap->fetch("$uidfirst:$to", '(uid flags internaldate envelope rfc822.size)') || {};
    $Self->{backfilling} = 1;
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($new->{$uid}{envelope});
      $didold++;
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, [$forcelabel], $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
    delete $Self->{backfilling};
  }

  if ($olduidnext > $olduidfirst) {
    my $to = $olduidnext - 1;
    my @extra;
    push @extra, "(changedsince $oldhighestmodseq)" if $oldhighestmodseq;
    $Self->log('debug', "UPDATING $imapname: $uidfirst:$to");
    my $changed = $imap->fetch("$uidfirst:$to", "(flags)", @extra) || {};
    foreach my $uid (sort { $a <=> $b } keys %$changed) {
      $Self->changed_record($ifolderid, $uid, $changed->{$uid}{'flags'}, [$forcelabel]);
    }
  }

  if ($uidnext > $olduidnext) {
    my $to = $uidnext - 1;
    $Self->log('debug', "FETCHING $imapname: $olduidnext:$to");
    my $new = $imap->fetch("$olduidnext:$to", '(uid flags internaldate envelope rfc822.size)') || {};
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($new->{$uid}{envelope});
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, [$forcelabel], $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  # need to make changes before counting
  my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
  if ($count != $exists) {
    my $to = $uidnext - 1;
    $Self->log('debug', "COUNTING $imapname: $uidfirst:$to (something deleted)");
    my $uids = $imap->search("UID", "$uidfirst:$to");
    my $data = $dbh->selectcol_arrayref("SELECT uid FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
    my %exists = map { $_ => 1 } @$uids;
    foreach my $uid (@$data) {
      next if $exists{$uid};
      $Self->deleted_record($ifolderid, $uid);
    }
  }

  $Self->dupdate('ifolders', {highestmodseq => $highestmodseq, uidfirst => $uidfirst, uidnext => $uidnext, uidvalidity => $uidvalidity}, {ifolderid => $ifolderid});

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
  my $imap = $Self->{imap};

  my %updatemap;
  foreach my $msgid (keys %$changes) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    $updatemap{$ifolderid}{$uid} = $changes->{$msgid};
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[3] => $_ } @$folderdata;

  foreach my $ifolderid (keys %updatemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    die "NO SUCH FOLDER $ifolderid" unless $imapname;

    # we're writing here!
    my $r = $imap->select($imapname);

    foreach my $uid (sort keys %{$updatemap{$ifolderid}}) {
      my $action = $updatemap{$ifolderid}{$uid};
      if (exists $action->{isUnread}) {
        my $act = $action->{isUnread} ? "-flags" : "+flags"; # reverse
        $Self->log('debug', "STORING $act SEEN for $uid");
        my $res = $imap->store($uid, $act, "(\\Seen)");
      }
      if (exists $action->{isFlagged}) {
        my $act = $action->{isFlagged} ? "+flags" : "-flags";
        $Self->log('debug', "STORING $act FLAGGED for $uid");
        $imap->store($uid, $act, "(\\Flagged)");
      }
      if (exists $action->{isAnswered}) {
        my $act = $action->{isAnswered} ? "+flags" : "-flags";
        $Self->log('debug', "STORING $act ANSWERED for $uid");
        $imap->store($uid, $act, "(\\Answered)");
      }
      if (exists $action->{mailboxIds}) {
        my $id = $action->{mailboxIds}->[0]; # there can be only one
        my $newfolder = $foldermap{$id}[1];
        $imap->copy($uid, $newfolder);  # UIDPLUS?  Also the ID changes
        $imap->store($uid, '+flags', "(\\Deleted)");
        $imap->uidexpunge($uid);
      }
    }
    $imap->unselect();
  }
}

sub delete_messages {
  my $Self = shift;
  my $ids = shift;

  my $dbh = $Self->{dbh};
  my $imap = $Self->{imap};

  my %deletemap;
  foreach my $msgid (@$ids) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    $deletemap{$ifolderid}{$uid} = 1;
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[3] => $_ } grep { $_->[3] } @$folderdata;

  foreach my $ifolderid (keys %deletemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    die "NO SUCH FOLDER $ifolderid" unless $imapname;

    # we're writing here!
    my $r = $imap->select($imapname);
    die "SELECT FAILED $r" unless lc($r) eq 'ok';

    my $uids = [sort keys %{$deletemap{$ifolderid}}];
    if (@$uids) {
      $imap->store($uids, "+flags", "(\\Deleted)");
      $imap->uidexpunge($uids);
    }
    $imap->unselect();
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
  my $envelope = decode_json(shift);
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

  my $imap = $Self->{imap};
  foreach my $ifolderid (sort keys %udata) {
    my ($imapname) = $Self->dbh->selectrow_array("SELECT imapname FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
    my $uhash = $udata{$ifolderid};

    die "NO folder $ifolderid" unless $imapname;
    my $r = $imap->examine($imapname);

    my $messages = $imap->fetch(join(',', sort { $a <=> $b } keys %$uhash), "rfc822");

    foreach my $uid (keys %$messages) {
      warn "FETCHED BODY FOR $uid\n";
      my $rfc822 = $messages->{$uid}{rfc822};
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
}

1;
