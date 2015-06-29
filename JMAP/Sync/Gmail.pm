#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Gmail;
use base qw(JMAP::DB);

use DBI;
use Mail::GmailTalk;
use Date::Parse;
use JSON::XS qw(encode_json decode_json);
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Encode;
use Encode::MIME::Header;
use Date::Format;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::GmailSMTP;
use IO::All;

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect);

sub new {
  my $Class = shift;
  my ($username, $refresh_token) = @_;
  return bless { username => $username, refresh_token => $refresh_token } ref($Class) || $Class;
}

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
  }
}

my $O;
sub O {
  unless ($O) {
    my $data = io->file("/home/jmap/jmap-perl/config.json")->slurp;
    my $config = decode_json($data);
    $O = OAuth2::Tiny->new(%$config);
  }
  return $O;
}

sub access_token {
  my $Self = shift;

  my $O = $Self->O();
  # XXX - cache this thing and check expiry?
  my $data = $O->refresh($Self->{refresh_token});

  return $data->{access_token};
}

sub connect {
  my $Self = shift;

  if ($Self->{imap}) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  for (1..3) {
    $Self->log('debug', "Looking for server for $Self->{accountid}");
    $Self->log('debug', "getting access token for $Self->{username}");
    my $token = $Self->access_token();
    my $port = 993;
    my $usessl = $port != 143;  # we use SSL for anything except default
    $Self->log('debug', "getting imaptalk");
    $Self->{imap} = Mail::GmailTalk->new(
      Server   => 'imap.gmail.com',
      Port     => $port,
      Username => $Self->{username},
      Password => $token,
      # not configurable right now...
      UseSSL   => $usessl,
      UseBlocking => $usessl,
    );
    next unless $Self->{imap};
    $Self->log('debug', "Connected as $Self->{username}");
    $Self->{lastused} = time();
    my @folders = $Self->{imap}->xlist('', '*');

    delete $Self->{folders};
    delete $Self->{labels};
    foreach my $folder (@folders) {
      my ($role) = grep { not $KNOWN_SPECIALS{lc $_} } @{$folder->[0]};
      my $name = $folder->[2];
      my $label = $role || $folder->[2];
      $Self->{folders}{$name} = $label;
      $Self->{labels}{$label} = $name;
    }
    return $Self->{imap};
  }

  die "Could not connect to IMAP server: $@";
}

sub send_email {
  my $Self = shift;
  my $rfc822 = shift;
  my $token = $Self->access_token();

  my $email = Email::Simple->new($rfc822);
  sendmail($email, {
    from => $Self->{username},
    transport => Email::Sender::Transport::GmailSMTP->new({
      host => 'smtp.gmail.com',
      port => 465,
      ssl => 1,
      sasl_username => $Self->{username},
      access_token => $token,
    })
  });
}

# read folder list from the server
sub folders {
  my $Self = shift;
  $Self->connect();
  return $Self->{folders};
}

sub labels {
  my $Self = shift;
  $Self->connect();
  return $Self->{labels};
}

sub do_folder {
  my $Self = shift;
  my $imapname = shift;
  my $data = shift || {uidvalidity => 0};
  my $batchsize = shift || 500;

  my $imap = $Self->connect();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $r" unless (lc($r) eq 'ok' or lc($r) eq 'read-only');

  my $uidvalidity = $imap->get_response_code('uidvalidity');
  my $uidnext = $imap->get_response_code('uidnext');
  my $highestmodseq = $imap->get_response_code('highestmodseq') || 0;
  my $exists = $imap->get_response_code('exists') || 0;

  if ($data->{uidvalidity} != $uidvalidity) {
    # force a delete/recreate and resync
    $data = {
      uidvalidity => $uidvalidity.
      highestmodseq => 0,
      uidfirst => 0,
      uidnext => 0,
    };
  }

  if ($data->{uidfirst} == 1 and $highestmodseq and $highestmodseq == $data->{highestmodseq}) {
    $Self->log('debug', "Nothing to do for $imapname at $highestmodseq");
    return 0; # yay, nothing to do
  }

  $data->{uidfirst} = $uidnext unless $data->{uidfirst};
  $data->{uidnext} = $uidnext unless $data->{uidnext};

  if ($data->{uidnext}) {
    my $from = 1;
    my $to = $data->{uidnext} - 1;
    my @extra;
    push @extra, "(changedsince $data->{highestmodseq})" if $data->{highestmodseq};
    $Self->log('debug', "UPDATING $imapname: $from:$to");
    my $changed = $imap->fetch("$from:$to", "(flags x-gm-labels)", @extra) || {};
    foreach my $uid (sort { $a <=> $b } keys %$changed) {
      $Self->changed_record($ifolderid, $uid, $changed->{$uid}{'flags'}, $forcelabel ? [$forcelabel] : $changed->{$uid}{'x-gm-labels'});
    }
  }

  if ($uidnext > $olduidnext) {
    my $to = $uidnext - 1;
    $Self->log('debug', "FETCHING $imapname: $olduidnext:$to");
    my $new = $imap->fetch("$olduidnext:$to", '(uid flags internaldate envelope rfc822.size x-gm-msgid x-gm-thrid x-gm-labels)') || {};
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, $forcelabel ? [$forcelabel] : $new->{$uid}{'x-gm-labels'}, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $new->{$uid}{'x-gm-msgid'}, $new->{$uid}{'x-gm-thrid'}, $new->{$uid}{'rfc822.size'});
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

  return $uidfirst;
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

sub import_message {
  my $Self = shift;
  my $message = shift;
  my $mailboxIds = shift;
  my %flags = @_;

  my $dbh = $Self->{dbh};
  my $imap = $Self->{imap};

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[3] => $_ } grep { $_->[3] } @$folderdata;

  # store to the first named folder - we can use labels on gmail to add to other folders later.
  my $foldername = $jmailmap{$mailboxIds->[0]}[1];
  $imap->select($foldername);

  my @flags;
  push @flags, "\\Seen" unless $flags{isUnread};
  push @flags, "\\Answered" if $flags{isAnswered};
  push @flags, "\\Flagged" if $flags{isFlagged};

  my $internaldate = time(); # XXX - allow setting?
  my $date = Date::Format::time2str('%e-%b-%Y %T %z', $internaldate);
  $imap->append($foldername, "(@flags)", $date, { Literal => $message });
  my $uid = $imap->get_response_code('appenduid');

  if (@$mailboxIds > 1) {
    my $labels = join(" ", grep { lc $_ ne '\\allmail' } map { $jmailmap{$_}[2] || $jmailmap{$_}[1] } @$mailboxIds);
    $imap->store($uid->[1], "X-GM-LABELS", "($labels)");
  }

  my $new = $imap->fetch($uid->[1], '(x-gm-msgid x-gm-thrid)');
  my $msgid = $new->{$uid->[1]}{'x-gm-msgid'};
  my $thrid = $new->{$uid->[1]}{'x-gm-thrid'};

  return ($msgid, $thrid);
}

sub update_messages {
  my $Self = shift;
  my $changes = shift;

  my @updated;
  my %notUpdated;

  my $dbh = $Self->{dbh};
  my $imap = $Self->{imap};

  my %updatemap;
  foreach my $msgid (keys %$changes) {
    my ($ifolderid, $uid) = $dbh->selectrow_array("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    $updatemap{$ifolderid}{$uid} = [$changes->{$msgid}, $msgid];
  }

  my $folderdata = $dbh->selectall_arrayref("SELECT ifolderid, imapname, label, jmailboxid FROM ifolders");
  my %foldermap = map { $_->[0] => $_ } @$folderdata;
  my %jmailmap = map { $_->[3] => $_ } grep { $_->[3] } @$folderdata;

  foreach my $ifolderid (keys %updatemap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}[1];
    die "NO SUCH FOLDER $ifolderid" unless $imapname;

    # we're writing here!
    my $r = $imap->select($imapname);
    die "SELECT FAILED $r" unless lc($r) eq 'ok';

    # XXX - error handling
    foreach my $uid (sort keys %{$updatemap{$ifolderid}}) {
      my $action = $updatemap{$ifolderid}{$uid}[0];
      my $msgid = $updatemap{$ifolderid}{$uid}[1];
      if (exists $action->{isUnread}) {
        my $act = $action->{isUnread} ? "-flags" : "+flags"; # reverse
        my $res = $imap->store($uid, $act, "(\\Seen)");
      }
      if (exists $action->{isFlagged}) {
        my $act = $action->{isFlagged} ? "+flags" : "-flags";
        $imap->store($uid, $act, "(\\Flagged)");
      }
      if (exists $action->{isAnswered}) {
        my $act = $action->{isAnswered} ? "+flags" : "-flags";
        $imap->store($uid, $act, "(\\Answered)");
      }
      if (exists $action->{mailboxIds}) {
        my $labels = join(" ", grep { lc $_ ne '\\allmail' } map { $jmailmap{$_}[2] || $jmailmap{$_}[1] } @{$action->{mailboxIds}});
        $imap->store($uid, "X-GM-LABELS", "($labels)");
      }
      push @updated, $msgid;
    }
    $imap->unselect();
  }

  return (\@updated, \%notUpdated);
}

sub delete_messages {
  my $Self = shift;
  my $ids = shift;

  my $dbh = $Self->{dbh};
  my $imap = $Self->{imap};

  my @deleted;
  my %notDeleted;

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

  return (\@deleted, \%notDeleted);
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
  @$labellist = ('\\allmail') unless @$labellist;

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
  return (
    msgsubject => decode('MIME-Header', $envelope->{Subject}),
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
    die "EXAMINE FAILED $r" unless lc($r) eq 'ok';

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
  refresh_token TEXT,
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

}

1;
