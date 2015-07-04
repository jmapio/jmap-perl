#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::GmailDB;
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
my %ROLE_MAP = (
  '\\Inbox' => 'inbox',
  '\\Drafts' => 'drafts',
  '\\Spam' => 'spam',
  '\\Trash' => 'trash',
  '\\AllMail' => 'archive',
  '\\Sent' => 'sent',
);

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
  }
}

sub setuser {
  my $Self = shift;
  my ($username, $refresh_token, $displayname, $picture) = @_;
  my $data = $Self->dbh->selectrow_arrayref("SELECT username, refresh_token FROM iserver");
  if ($data and $data->[0]) {
    $Self->dmaybeupdate('iserver', {username => $username, refresh_token => $refresh_token});
  }
  else {
    $Self->dinsert('iserver', {
      username => $username,
      refresh_token => $refresh_token,
    });
  }
  my $user = $Self->dbh->selectrow_arrayref("SELECT email, displayname FROM account");
  if ($user and $user->[0]) {
    $Self->dmaybeupdate('account', {email => $username, displayname => $displayname, picture => $picture});
  }
  else {
    $Self->dinsert('account', {
      email => $username,
      displayname => $displayname,
      picture => $picture,
      jdeletedmodseq => 0,
      jhighestmodseq => 1,
    });
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
  my $username = shift;
  my $refresh_token = shift;

  unless ($refresh_token) {
    ($username, $refresh_token) = $Self->dbh->selectrow_array("SELECT username, refresh_token FROM iserver");
  }

  my $O = $Self->O();
  my $data = $O->refresh($refresh_token);

  return ['gmail', $username, $data->{access_token}];
}

sub connect {
  my $Self = shift;

  if ($Self->{imap}) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  for (1..3) {
    $Self->log('debug', "Looking for server for $Self->{accountid}");
    my $data = $Self->dbh->selectrow_arrayref("SELECT username, refresh_token, lastfoldersync FROM iserver");
    die "UNKNOWN SERVER for $Self->{accountid}" unless ($data and $data->[0]);
    $Self->log('debug', "getting access token for $data->[0]");
    my $token = $Self->access_token($data->[0], $data->[1]);
    my $port = 993;
    my $usessl = $port != 143;  # we use SSL for anything except default
    $Self->log('debug', "getting imaptalk");
    $Self->{imap} = Mail::GmailTalk->new(
      Server   => 'imap.gmail.com',
      Port     => $port,
      Username => $data->[0],
      Password => $token->[2],   # bogus, but here we go...
      # not configurable right now...
      UseSSL   => $usessl,
      UseBlocking => $usessl,
    );
    next unless $Self->{imap};
    $Self->log('debug', "Connected as $data->[0]");
    $Self->begin();
    $Self->sync_folders();
    $Self->dmaybeupdate('iserver', {lastfoldersync => time()}, {username => $data->[0]});
    $Self->commit();
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  die "Could not connect to IMAP server: $@";
}

sub send_email {
  my $Self = shift;
  my $rfc822 = shift;
  my $data = $Self->dbh->selectrow_arrayref("SELECT username, refresh_token FROM iserver");
  die "UNKNOWN SERVER for $Self->{accountid}" unless ($data and $data->[0]);
  my $token = $Self->access_token($data->[0], $data->[1]);
  die "not gmail" unless $token->[0] eq 'gmail';

  my $email = Email::Simple->new($rfc822);
  sendmail($email, { 
    from => $data->[0],
    transport => Email::Sender::Transport::GmailSMTP->new({
      host => 'smtp.gmail.com',
      port => 465,
      ssl => 1,
      sasl_username => $token->[1],
      access_token => $token->[2],
    })
  });
}

# synchronise list from IMAP server to local folder cache
# call in transaction
sub sync_folders {
  my $Self = shift;

  my $dbh = $Self->dbh();
  my $imap = $Self->{imap};

  my @folders = $imap->xlist('', '*');
  my $ifolders = $dbh->selectall_arrayref("SELECT ifolderid, sep, imapname, label FROM ifolders");
  my %ibylabel = map { $_->[3] => $_ } @$ifolders;
  my %seen;

  foreach my $folder (@folders) {
    my ($role) = grep { not $KNOWN_SPECIALS{lc $_} } @{$folder->[0]};
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

our %PROTECTED_MAILBOXES = map { $_ => 1 } qw(inbox trash archive junk);
our %ONLY_MAILBOXES = map { $_ => 1 } qw(trash);
our %NO_RENAME = map { $_ => 1 } qw(inbox);

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
    $byname{$mailbox->[2]||'0'}{$mailbox->[1]} = $mailbox->[0];
  }

  my %seen;
  foreach my $folder (@$ifolders) {
    # check for roles first
    my $role = $ROLE_MAP{$folder->[3]};
    my @bits = split $folder->[1], $folder->[2];
    my $id = 0;
    my $parentid = 0;
    my $name;
    my $precedence = 3;
    $precedence = 1 if ($role||'' eq 'inbox');
    while (my $item = shift @bits) {
      if ($item eq '[Gmail]') {
        $precedence = 2 if $role;
        next;
      }
      $name = $item;
      $parentid = $id;
      $id = $byname{$parentid}{$name};
      unless ($id) {
        if (@bits) {
          # need to create intermediate folder ...
          $id = $Self->dmake('jmailboxes', {name => $name, parentid => $parentid});
          $byname{$parentid}{$name} = $id;
        }
      }
    }
    next unless $name;
    my %details = (
      name => $name,
      parentid => $parentid,
      precedence => $precedence,
      mustBeOnly => $ONLY_MAILBOXES{$role||''},
      mayDelete => (not $PROTECTED_MAILBOXES{$role||''}),
      mayRename => (not $NO_RENAME{$role||''}),
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

  my $haveoutbox = 0;
  foreach my $mailbox (@$jmailboxes) {
    my $id = $mailbox->[0];
    if (($mailbox->[3]||'') eq 'outbox') {
      $haveoutbox = 1;
      next;
    }
    next if $seen{$id};
    $Self->dupdate('jmailboxes', {active => 0}, {jmailboxid => $id});
  }

  unless ($haveoutbox) {
    $Self->dmake('jmailboxes', {
      role => "outbox",
      name => "Outbox",
      parentid => 0,
      precedence => 1,
      mustBeOnly => 0,
      mayDelete => 0,
      mayRename => 0,
      mayAdd => 1,
      mayRemove => 1,
      mayChild => 0, # don't go fiddling around
      mayRead => 1,
    });
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
  my $labels = $Self->labels();

  # there's some special casing to care about here... we force the \\Trash label on Trash UIDs
  $Self->do_folder($labels->{"\\allmail"}[0]);
  if ($labels->{"\\trash"}[0]) {
    $Self->do_folder($labels->{"\\trash"}[0], "\\Trash");
  }
}

sub backfill {
  my $Self = shift;
  my $old = $Self->dbh->selectcol_arrayref("SELECT ifolderid FROM ifolders WHERE uidnext > 1 AND uidfirst > 1");
  foreach my $ifolderid (@$old) {
    warn "SYNCING OLD FOLDER $ifolderid\n";
    $Self->do_folder($ifolderid);
  }
}

sub firstsync {
  my $Self = shift;
  my $imap = $Self->{imap};
  my $labels = $Self->labels();

  my $ifolderid = $labels->{"\\allmail"}[0];
  $Self->do_folder($ifolderid, undef, 50);

  my $msgids = $Self->dbh->selectcol_arrayref("SELECT msgid FROM imessages WHERE ifolderid = ? ORDER BY uid DESC LIMIT 50", {}, $ifolderid);

  # pre-load the INBOX!
  $Self->fill_messages(@$msgids);
}

sub do_folder {
  my $Self = shift;
  my $ifolderid = shift;
  my $forcelabel = shift;
  my $batchsize = shift || 500;

  Carp::confess("NO FOLDERID") unless $ifolderid;
  my $imap = $Self->{imap};
  my $dbh = $Self->dbh();

  my ($imapname, $olduidfirst, $olduidnext, $olduidvalidity, $oldhighestmodseq) = $dbh->selectrow_array("SELECT imapname, uidfirst, uidnext, uidvalidity, highestmodseq FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
  die "NO SUCH FOLDER $ifolderid" unless $imapname;
  $olduidfirst ||= 0;

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $r" unless (lc($r) eq 'ok' or lc($r) eq 'read-only');

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
  if ($olduidfirst > 1) {
    $uidfirst = $olduidfirst - $batchsize;
    $uidfirst = 1 if $uidfirst < 1;
    my $to = $olduidfirst - 1;
    $Self->log('debug', "FETCHING $imapname: $uidfirst:$to");
    my $new = $imap->fetch("$uidfirst:$to", '(uid flags internaldate envelope rfc822.size x-gm-msgid x-gm-thrid x-gm-labels)') || {};
    $Self->{backfilling} = 1;
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, $forcelabel ? [$forcelabel] : $new->{$uid}{'x-gm-labels'}, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $new->{$uid}{'x-gm-msgid'}, $new->{$uid}{'x-gm-thrid'}, $new->{$uid}{'rfc822.size'});
    }
    delete $Self->{backfilling};
  }

  if ($olduidnext > $olduidfirst) {
    my $to = $olduidnext - 1;
    my @extra;
    push @extra, "(changedsince $oldhighestmodseq)" if $oldhighestmodseq;
    $Self->log('debug', "UPDATING $imapname: $uidfirst:$to");
    my $changed = $imap->fetch("$uidfirst:$to", "(flags x-gm-labels)", @extra) || {};
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

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icalendars (
  icalendarid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  colour TEXT,
  syncToken TEXT,
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
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ientries (
  ientryid INTEGER PRIMARY KEY NOT NULL,
  iabookid INTEGER,
  resource TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

}

1;
