#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Common;

use Data::UUID::LibUUID;
use Mail::IMAPTalk;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTPS;
use Net::CalDAVTalk;
use Net::CardDAVTalk;
use MIME::Base64 qw(decode_base64);
use MIME::QuotedPrint qw(decode_qp);
use Sys::Hostname;

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

# --- Hook methods (subclasses override as needed) ---

sub _imap_class { 'Mail::IMAPTalk' }
sub _imap_ssl   { 1 }
sub _imap_auth  { my $Self = shift; (Password => $Self->{auth}{password}) }
sub _imap_extra { () }

sub _caldav_url  { $_[0]->{auth}{caldavURL} }
sub _carddav_url { $_[0]->{auth}{carddavURL} }
sub _dav_auth    { my $Self = shift; (password => $Self->{auth}{password}) }

# --- Connection methods ---

sub connect_imap {
  my $Self  = shift;
  my $force = shift;

  if ($Self->{imap} and not $force) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  if ($Self->{imap}) {
    $Self->{imap}->disconnect();
    delete $Self->{imap};
  }

  my $usessl = $Self->_imap_ssl();
  for (1..3) {
    $Self->{imap} = $Self->_imap_class()->new(
      Server        => $Self->{auth}{imapHost},
      Port          => $Self->{auth}{imapPort},
      Username      => $Self->{auth}{username},
      $Self->_imap_auth(),
      UseSSL        => $usessl,
      UseBlocking   => $usessl,
      PreserveINBOX => 1,
      $Self->_imap_extra(),
    );
    next unless $Self->{imap};
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  die "Could not connect to IMAP server: $@";
}

sub connect_calendars {
  my $Self = shift;
  my $url  = $Self->_caldav_url() or return;

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::CalDAVTalk->new(
    user      => $Self->{auth}{username},
    $Self->_dav_auth(),
    url       => $url,
    expandurl => 1,
  );

  return $Self->{calendars};
}

sub connect_contacts {
  my $Self = shift;
  my $url  = $Self->_carddav_url() or return;

  if ($Self->{contacts}) {
    $Self->{lastused} = time();
    return $Self->{contacts};
  }

  $Self->{contacts} = Net::CardDAVTalk->new(
    user      => $Self->{auth}{username},
    $Self->_dav_auth(),
    url       => $url,
    expandurl => 1,
  );

  return $Self->{contacts};
}

sub send_email {
  my $Self     = shift;
  my $rfc822   = shift;
  my $envelope = shift;

  my %args;
  if ($envelope) {
    $args{from} = $envelope->{mailFrom}{email};
    $args{to}   = [ map { $_->{email} } @{$envelope->{rcptTo}} ];
  } else {
    $args{from} = $Self->{auth}{username};
  }

  my $helo  = $ENV{HOSTNAME} || hostname();
  my $email = Email::Simple->new($rfc822);
  sendmail($email, {
    %args,
    transport => $Self->_smtp_transport($helo),
  });
  warn "send_email: sent from $args{from}\n";
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
    $res{$item->{href}} = $item->{_raw};
  }

  return \%res;
}

sub get_events_multi {
  my $Self = shift;
  my $collection = shift;
  my $hrefs = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $collection =~ s{/$}{};
  my ($data, $errors, $links) = $talk->GetEventsMulti($collection, $hrefs, Full => 1);

  my %res;
  foreach my $item (@$data) {
    $res{$item->{href}} = $item->{_raw};
  }

  return (\%res, $errors, $links);
}

sub sync_event_links {
  my $Self = shift;
  my $collection = shift;
  my $oldtoken = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $collection =~ s{/$}{};
  my ($added, $removed, $errors, $newtoken) = $talk->SyncEventLinks($collection, syncToken => $oldtoken);

  return ($added, $removed, $errors, $newtoken);
}

sub new_calendar {
  my $Self = shift;
  my $args = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $talk->NewCalendar($args);
}

sub update_calendar {
  my $Self = shift;
  my $args = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $talk->UpdateCalendar($args);
}

sub delete_calendar {
  my $Self = shift;
  my $id = shift;

  my $talk = $Self->connect_calendars();
  return unless $talk;

  $talk->DeleteCalendar($id);
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

sub update_event_occurrence {
  my ($Self, $href, $recurrenceId, $patch) = @_;
  my $talk = $Self->connect_calendars();
  return unless $talk;

  my $event = $talk->GetEvent($href)
    or die "Could not fetch event for occurrence update: $href\n";

  # Both field-name variants appear in the wild
  my %overrides = %{$event->{recurrenceOverrides} || $event->{exceptions} || {}};

  if (defined $patch) {
    my %override = %{$overrides{$recurrenceId} || {}};
    for my $key (keys %$patch) {
      if (defined $patch->{$key}) { $override{$key} = $patch->{$key} }
      else                        { delete $override{$key}             }
    }
    $overrides{$recurrenceId} = \%override;
  } else {
    $overrides{$recurrenceId} = undef;  # exclude this occurrence (iCal EXDATE)
  }

  $talk->UpdateEvent($href, { recurrenceOverrides => \%overrides });
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

sub get_cards_multi {
  my $Self = shift;
  my $collection = shift;
  my $hrefs = shift;

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $collection =~ s{/$}{};
  my ($data, $errors, $links) = $talk->GetContactsMulti($collection, $hrefs, []);

  my %res;
  foreach my $item (@$data) {
    $res{$item->{href}} = $item->{_raw};
  }

  return (\%res, $errors, $links);
}

sub get_card_links {
  my $Self = shift;
  my $collection = shift;

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $collection =~ s{/$}{};
  my $links = $talk->GetContactLinks($collection);

  return $links;
}

sub sync_card_links {
  my $Self = shift;
  my $collection = shift;
  my $oldtoken = shift;

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $collection =~ s{/$}{};
  my ($added, $removed, $errors, $newtoken) = $talk->SyncContactLinks($collection, syncToken => $oldtoken);

  return ($added, $removed, $errors, $newtoken);
}

sub new_addressbook {
  my $Self = shift;
  my $args = shift;  # { id => ..., name => ... }

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $talk->NewAddressBook($args->{id}, name => $args->{name});
}

sub update_addressbook {
  my $Self = shift;
  my $args = shift;  # { id => ..., name => ... }

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $talk->UpdateAddressBook($args->{id}, name => $args->{name});
}

sub delete_addressbook {
  my $Self = shift;
  my $id = shift;

  my $talk = $Self->connect_contacts();
  return unless $talk;

  $talk->DeleteAddressBook($id);
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
  my $sep    = $namespace->[0][0][1];
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

  return [$prefix, \%folders, $sep];
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

sub imap_getuniqueid {
  my $Self = shift;
  my $folders = shift;

  my $imap = $Self->connect_imap();

  return {} unless $imap->capability->{xconversations};  # don't bother unless it's FastMail

  my $metadata = $imap->multigetmetadata('/shared/vendor/cmu/cyrus-imapd/uniqueid', $folders);

  return $metadata;
}

sub imap_myrights {
  my $Self = shift;
  my $folders = shift;

  my $imap = $Self->connect_imap();

  return {} unless $imap->capability->{acl};

  my %rights;
  for my $name (@$folders) {
    my (undef, $r) = $imap->myrights($name);
    $rights{$name} = $r if defined $r;
  }
  return \%rights;
}

# no newname == delete
sub imap_update {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
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

  $imap->store($uids, "flags", "(@$flags)");
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

sub imap_copy {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $newname = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

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

  my $res = $imap->copy($uids, $newname);
  unless ($res) {
    $res{notCopied} = $uids;
    return \%res;
  }
  $Self->_unselect($imap);

  $res{copied} = $uids;

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
    my $getimmutable = $item->[2];
    $to = $uidnext - 1 if $to eq '*';
    next if $from > $to;
    my @flags = qw(uid flags);
    push @flags, qw(x-gm-labels) if $imap->capability->{'x-gm-ext-1'};
    if ($getimmutable) {
      push @flags, qw(internaldate envelope rfc822.size);
      push @flags, qw(x-gm-msgid x-gm-thrid) if $imap->capability->{'x-gm-ext-1'};
      push @flags, qw(cid digest.sha1) if $imap->capability->{'xconversations'};
    }
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

  unless ($res) {
    my $err = $imap->get_last_error();
    if ($err =~ m/Response was : (\w+) - (.*)/) {
      return ['create', $1, $2];
    }
    return ['create', $res];
  }

  my $data = $Self->imap_status([$imapname]);

  return ['create', 'ok', $data->{$imapname}];
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
