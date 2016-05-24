#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Common;

use Mail::IMAPTalk;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTPS;
use Net::CalDAVTalk;
use Net::CardDAVTalk;
use MIME::Base64 qw(decode_base64);
use MIME::QuotedPrint qw(decode_qp);

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect \\NoInferiors);

sub new {
  my $Class = shift;
  my $auth = shift;
  return bless { auth => $auth }, ref($Class) || $Class;
}

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
    delete $Self->{imap};
  }
}

sub _unselect {
  my $Self = shift;
  my $imap = shift;
  if ($imap->capability->{unselect}) {
    $imap->unselect();
  }
  else {
    $imap->close();
  }
}

sub disconnect {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
    delete $Self->{imap};
  }
}

sub get_calendars {
  my $Self = shift;
  my $talk = $Self->connect_calendars();
  return unless $talk;

  my $data = $talk->GetCalendars(Sync => 1);

  return $data;
}

sub get_events {
  my $Self = shift;
  my $collection = shift;
  my $talk = $Self->connect_calendars();
  return unless $talk;

  $collection =~ s{/$}{};
  my $data = $talk->GetEvents($collection, Full => 1);

  my %res;
  foreach my $item (@$data) {
    $res{$item->{id}} = $item->{_raw};
  }

  return \%res;
}

sub new_event {
  my $Self = shift;
  my $collection = shift; # is collection of the calendar
  my $event = shift;
  $collection =~ s{/$}{};

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $talk->NewEvent($collection, $event);
}

sub update_event {
  my $Self = shift;
  my $resource = shift;
  my $event = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $talk->UpdateEvent($resource, $event);
}

sub delete_event {
  my $Self = shift;
  my $resource = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $talk->DeleteEvent($resource);  # XXX - we pass more properties for no good reason to this API
}

sub get_addressbooks {
  my $Self = shift;
  my $talk = $Self->connect_contacts();
  return unless $talk;

  my $data = $talk->GetAddressBooks(Sync => 1);

  return $data;
}

sub get_cards {
  my $Self = shift;
  my $collection = shift;
  my $talk = $Self->connect_contacts();
  return unless $talk;

  $collection =~ s{/$}{};
  my $data = $talk->GetContacts($collection);

  my %res;
  foreach my $item (@$data) {
    $res{$item->{CPath}} = $item->{_raw};
  }

  return \%res;
}

sub new_card {
  my $Self = shift;
  my $collection = shift;
  my $card = shift;
  $collection =~ s{/$}{};

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $talk->NewContact($collection, $card);
}

sub update_card {
  my $Self = shift;
  my $resource = shift;
  my $card = shift;

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $talk->UpdateContact($resource, $card);
}

sub delete_card {
  my $Self = shift;
  my $resource = shift;

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $talk->DeleteContact($resource);
}

# read folder list from the server
sub folders {
  my $Self = shift;
  my $force = shift;

  my $imap = $Self->connect_imap();

  my $namespace = $imap->namespace();
  my $prefix = $namespace->[0][0][0];
  my $listcmd = $imap->capability()->{xlist} ? 'xlist' : 'list';
  my @folders = $imap->$listcmd('', '*');

  my %folders;
  foreach my $folder (@folders) {
    my ($role) = grep { not $KNOWN_SPECIALS{lc $_} } @{$folder->[0]};
    my $name = $folder->[2];
    my $label;
    if ($role) {
      $label = $role;
    }
    else {
      $label = $folder->[2];
      $label =~ s{^$prefix}{};
      $label =~ s{^[$folder->[1]]}{}; # just in case prefix was missing sep
    }
    $folders{$name} = [$folder->[1], $label];
  }

  return [$prefix, \%folders];
}

sub capability {
  my $Self = shift;
  my $imap = $Self->connect_imap();
  return $imap->capability();
}

sub imap_noop {
  my $Self = shift;
  my $folders = shift;

  my $imap = $Self->connect_imap();

  $imap->noop();
}

sub imap_status {
  my $Self = shift;
  my $folders = shift;

  my $imap = $Self->connect_imap();

  my @fields = qw(uidvalidity uidnext messages);
  push @fields, "highestmodseq" if ($imap->capability->{condstore} or $imap->capability->{xymhighestmodseq});
  my $data = $imap->multistatus("(@fields)", @$folders);

  return $data;
}

# no newname == delete
sub imap_update {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $isAdd = shift;
  my $flags = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->select($imapname);
  die "SELECT FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  $imap->store($uids, $isAdd ? "+flags" : "-flags", "(@$flags)");
  $Self->_unselect($imap);

  $res{updated} = $uids;

  return \%res;
}

sub imap_fill {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  my $data = $imap->fetch($uids, "rfc822");
  $Self->_unselect($imap);

  my %ids;
  foreach my $uid (keys %$data) {
    $ids{$uid} = $data->{$uid}{rfc822};
  }
  $res{data} = \%ids;
  return \%res;
}

sub _get_bs_part {
  my ($bs, $part) = @_;
  return $bs if ($bs->{'IMAP-Partnum'} eq $part);
  return unless $bs->{'MIME-Subparts'};
  foreach my $sub (@{$bs->{'MIME-Subparts'}}) {
    my $res = _get_bs_part($sub, $part);
    return $res if $res;
  }
  return;
}

sub _decode_bs_part {
  my ($data, $bs, $part) = @_;
  use Data::Dumper;
  my $info = _get_bs_part($bs, $part);
  my $enc = $info->{'Content-Transfer-Encoding'};

  my $res = $data;
  if ($enc =~ m/base64/i) {
    $res = decode_base64($data);
  }
  elsif ($enc =~ m/quoted-print/i) {
    $res = decode_qp($data);
  }

  return $res;
}

sub imap_getpart {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uid = shift;
  my $part = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  if ($part) {
    if ($imap->capability->{binary}) {
      my $data = $imap->fetch($uid, "BINARY[$part]");
      $res{data} = $data->{$uid}{'binary'};
    }
    else {
      # tricky case!  We've going to have to ask for the bodystructure and parse out the CTE
      my $data = $imap->fetch($uid, "(BODY[$part] BODYSTRUCTURE)");
      $res{data} = _decode_bs_part($data->{$uid}{'body'}, $data->{$uid}{'bodystructure'}, $part);
    }
  }
  else {
    my $data = $imap->fetch($uid, "RFC822");
    $res{data} = $data->{$uid}{'rfc822'};
  }

  $Self->_unselect($imap);

  return \%res;
}

sub imap_count {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  my $data = $imap->search('uid', $uids);
  $Self->_unselect($imap);

  $res{data} = $data;
  return \%res;
}

# no newname == delete
sub imap_move {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $newname = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->select($imapname);
  die "SELECT FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    newname => $newname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  if ($newname) {
    # move
    if ($imap->capability->{move}) {
      my $res = $imap->move($uids, $newname);
      unless ($res) {
        $res{notMoved} = $uids;
        return \%res;
      }
    }
    else {
      my $res = $imap->copy($uids, $newname);
      unless ($res) {
        $res{notMoved} = $uids;
        return \%res;
      }
      $imap->store($uids, "+flags", "(\\seen \\deleted)");
      $imap->uidexpunge($uids);
    }
  }
  else {
    $imap->store($uids, "+flags", "(\\seen \\deleted)");
    $imap->uidexpunge($uids);
  }
  $Self->_unselect($imap);

  $res{moved} = $uids;

  return \%res;
}

sub imap_fetch {
  my $Self = shift;
  my $imapname = shift;
  my $state = shift || {};
  my $fetch = shift || {};

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;
  my $uidnext = $imap->get_response_code('uidnext') + 0;
  my $highestmodseq = $imap->get_response_code('highestmodseq') || 0;
  my $exists = $imap->get_response_code('exists') || 0;

  my %res = (
    imapname => $imapname,
    oldstate => $state,
    newstate => {
      uidvalidity => $uidvalidity + 0,
      uidnext => $uidnext + 0,
      highestmodseq => $highestmodseq + 0,
      exists => $exists + 0,
    },
  );

  if (($state->{uidvalidity} || 0) != $uidvalidity) {
    warn "UIDVALID $state->{uidvalidity} $uidvalidity\n";
    $res{uidfail} = 1;
    return \%res;
  }

  foreach my $key (keys %$fetch) {
    my $item = $fetch->{$key};
    my $from = $item->[0];
    my $to = $item->[1];
    $to = $uidnext - 1 if $to eq '*';
    next if $from > $to;
    my @flags = qw(uid flags);
    push @flags, @{$item->[2]} if $item->[2];
    next if ($highestmodseq and $item->[3] and $item->[3] == $highestmodseq);
    my @extra;
    push @extra, "(changedsince $item->[3])" if ($item->[3] and $imap->capability->{condstore});
    my $data = $imap->fetch("$from:$to", "(@flags)", @extra) || {};
    $res{$key} = [$item, $data];
  }
  $Self->_unselect($imap);

  return \%res;
}

sub imap_append {
  my $Self = shift;
  my $imapname = shift;
  my $flags = shift;
  my $internaldate = shift;
  my $rfc822 = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->append($imapname, $flags, $internaldate, {'Literal' => $rfc822});
  die "APPEND FAILED $r" unless (lc($r) eq 'ok' or lc($r) eq 'appenduid'); # what's with that??

  my $response = $imap->get_response_code('appenduid');
  my ($uidvalidity, $uid) = @$response;

  # XXX - fetch the x-gm-msgid or envelope from the server so we know the
  # the ID that the server gave this message

  return ['append', $imapname, $uidvalidity, $uid];
}

sub imap_search {
  my $Self = shift;
  my $imapname = shift;
  my @expr = @_;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  # XXX - check uidvalidity
  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;
  my $uidnext = $imap->get_response_code('uidnext') + 0;
  my $highestmodseq = $imap->get_response_code('highestmodseq') || 0;
  my $exists = $imap->get_response_code('exists') || 0;

  if ($imap->capability->{'search=fuzzy'}) {
    @expr = ('fuzzy', [@expr]);
  }

  my $uids = $imap->search('charset', 'utf-8', @expr);
  $Self->_unselect($imap);

  return ['search', $imapname, $uidvalidity, $uids];
}

sub create_mailbox {
  my $Self = shift;
  my $imapname = shift;

  my $imap = $Self->connect_imap();

  my $res = $imap->create($imapname);

  my @res = ($res);
  unless ($res) {
    my $err = $imap->get_last_error();
    if ($err =~ m/Response was : (\w+) - (.*)/) {
      @res = ($1, $2);
    }
  }

  return ['create', @res];
}

sub rename_mailbox {
  my $Self = shift;
  my $oldname = shift;
  my $imapname = shift;

  my $imap = $Self->connect_imap();

  my $res = $imap->rename($oldname, $imapname);

  my @res = ($res);
  unless ($res) {
    my $err = $imap->get_last_error();
    if ($err =~ m/Response was : (\w+) - (.*)/) {
      @res = ($1, $2);
    }
  }

  return ['rename', @res];
}

sub delete_mailbox {
  my $Self = shift;
  my $imapname = shift;

  my $imap = $Self->connect_imap();

  my $res = $imap->delete($imapname);

  my @res = ($res);
  unless ($res) {
    my $err = $imap->get_last_error();
    if ($err =~ m/Response was : (\w+) - (.*)/) {
      @res = ($1, $2);
    }
  }

  return ['delete', @res];
}

1;
