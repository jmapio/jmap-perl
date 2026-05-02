#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::DB;

use Data::Dumper;
use DBI;
use DBI qw(:sql_types);
use Carp qw(confess);

use Sys::Hostname;
use Data::UUID::LibUUID;
use IO::LockedFile;
use JSON::XS qw(decode_json);
use Email::MIME;
# seriously, it's parsable, get over it
$Email::MIME::ContentType::STRICT_PARAMS = 0;
use HTML::Strip;
use Image::Size;
use Email::Address::XS qw(parse_email_groups);
use Email::MIME::Header::AddressList;
use Encode;
use Encode::MIME::Header;
use DateTime;
use Date::Parse;
use Date::Format;
use Net::CalDAVTalk;
use Text::JSContact qw(vcard_to_jscontact jscontact_to_vcard);
use MIME::Base64 qw(encode_base64 decode_base64);
use Scalar::Util qw(weaken);
use Data::JSEmail;

my $json = JSON::XS->new->utf8->canonical();

my %TABLE2GROUPS = (
  jmessages => ['Email'],
  jthreads => ['Thread'],
  jmailboxes => ['Mailbox'],
  jmessagemap => ['Mailbox'],
  jrawmessage => [],
  jfiles => [], # for now
  jcalendars => ['Calendar'],
  jevents => ['CalendarEvent'],
  jaddressbooks => [], # not directly
  jcontactgroups => ['ContactGroup'],
  jcontactgroupmap => ['ContactGroup'],
  jcontacts => ['Contact'],
  jsubmission => ['EmailSubmission'],
  jclientprefs => ['ClientPreferences'],
  jcalendarprefs => ['CalendarPreferences'],
);

our $DATADIR = $ENV{JMAP_DATADIR} || '/home/jmap/data';

sub new {
  my $class = shift;
  my $accountid = shift || die;
  my $Self = bless { accountid => $accountid, start => time() }, ref($class) || $class;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$DATADIR/$accountid.sqlite3");
  $Self->_initdb($dbh);
  return $Self;
}

sub _acct_dir {
  my ($Self) = @_;
  my $dir = "$DATADIR/" . $Self->accountid;
  mkdir $dir unless -d $dir;
  return $dir;
}

sub _subdir_path {
  my ($Self, $subdir, $key) = @_;
  my $dir = $Self->_acct_dir . "/$subdir";
  mkdir $dir unless -d $dir;
  return "$dir/$key";
}

sub read_subdir {
  my ($Self, $subdir, $key) = @_;
  my $path = $Self->_subdir_path($subdir, $key);
  return undef unless -f $path;
  open my $fh, '<:raw', $path or die "Cannot read $path: $!";
  local $/; my $data = <$fh>; close $fh;
  return $data;
}

sub write_subdir {
  my ($Self, $subdir, $key, $data) = @_;
  my $path = $Self->_subdir_path($subdir, $key);
  open my $fh, '>:raw', $path or die "Cannot write $path: $!";
  print $fh $data; close $fh;
}

sub unlink_subdir {
  my ($Self, $subdir, $key) = @_;
  unlink $Self->_subdir_path($subdir, $key);
}

sub read_parsed_msg     { my $b = $_[0]->read_subdir('parsed',   "$_[1].json"); defined $b ? decode_json($b) : undef }
sub write_parsed_msg    { $_[0]->write_subdir('parsed',   "$_[1].json", $json->encode($_[2])) }

sub read_upload_blob    { $_[0]->read_subdir('files',    $_[1]) }
sub write_upload_blob   { $_[0]->write_subdir('files',   $_[1], $_[2]) }

sub read_event_ical     { $_[0]->read_subdir('events',   "$_[1].ics") }
sub write_event_ical    { $_[0]->write_subdir('events',  "$_[1].ics", $_[2]) }
sub unlink_event_ical   { $_[0]->unlink_subdir('events', "$_[1].ics") }

sub read_card_vcf       { $_[0]->read_subdir('cards',    "$_[1].vcf") }
sub write_card_vcf      { $_[0]->write_subdir('cards',   "$_[1].vcf", $_[2]) }
sub unlink_card_vcf     { $_[0]->unlink_subdir('cards',  "$_[1].vcf") }

sub read_jevent_payload    { my $b = $_[0]->read_subdir('jevents',   "$_[1].json"); defined $b ? decode_json($b) : undef }
sub write_jevent_payload   { $_[0]->write_subdir('jevents',   "$_[1].json", $json->encode($_[2])) }
sub unlink_jevent_payload  { $_[0]->unlink_subdir('jevents',  "$_[1].json") }

sub read_jcontact_payload  { my $b = $_[0]->read_subdir('jcontacts', "$_[1].json"); defined $b ? decode_json($b) : undef }
sub write_jcontact_payload { $_[0]->write_subdir('jcontacts', "$_[1].json", $json->encode($_[2])) }
sub unlink_jcontact_payload{ $_[0]->unlink_subdir('jcontacts',"$_[1].json") }

sub delete {
  my $Self = shift;
  my $accountid = $Self->accountid();
  delete $Self->{dbh};
  unlink("$DATADIR/$accountid.sqlite3");
  my $dir = "$DATADIR/$accountid";
  if (-d $dir) {
    for my $sub (glob("$dir/*")) {
      if (-d $sub) {
        unlink $_ for glob("$sub/*");
        rmdir $sub;
      }
    }
    rmdir $dir;
  }
}

sub accountid {
  my $Self = shift;
  return $Self->{accountid};
}

sub log {
  my $Self = shift;
  if ($Self->{logger}) {
    $Self->{logger}->(@_);
  }
  else {
    my ($level, @items) = @_;
    return if (not $ENV{DEBUGDB} and $level eq 'debug');
    my $time = time() - $Self->{start};
    warn "[$$ $level $time]: @items\n";
  }
}

sub dbh {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  return $Self->{t}{dbh};
}

sub in_transaction {
  my $Self = shift;
  return $Self->{t} ? 1 : 0;
}

sub begin_superlock {
  my $Self = shift;
  my $accountid = $Self->accountid();
  my $lock = IO::LockedFile->new(">$DATADIR/$accountid.lock");
  $Self->{superlock} = $lock;
  weaken $Self->{superlock};
  return $lock;
}

sub begin {
  my $Self = shift;
  confess("ALREADY IN TRANSACTION") if $Self->{t};
  my $accountid = $Self->accountid();
  # we need this because sqlite locking isn't as robust as you might hope
  $Self->{t} = {lock => $Self->{superlock} || IO::LockedFile->new(">$DATADIR/$accountid.lock")};
  $Self->{t}{dbh} = DBI->connect("dbi:SQLite:dbname=$DATADIR/$accountid.sqlite3");
  $Self->{t}{dbh}->begin_work();
}

sub commit {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};

  # push an update if anything to tell..
  my $t = $Self->{t};

  my $mbupdates = delete $t->{update_mailbox_counts};
  if ($mbupdates) {
    foreach my $jmailboxid (keys %$mbupdates) {
      my %update;
      # re-calculate all the counts.  In theory we could do something clever with delta updates, but this will work
      ($update{totalEmails}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $jmailboxid);
      ($update{unreadEmails}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.isUnread = 1 AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $jmailboxid);
      ($update{totalThreads}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT thrid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $jmailboxid);
      ($update{unreadThreads}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT thrid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1 AND thrid IN (SELECT thrid FROM jmessages JOIN jmessagemap USING (msgid) WHERE isUnread = 1 AND jmessages.active = 1 AND jmessagemap.active = 1)", {}, $jmailboxid);

      $update{$_} += 0 for keys %update;  # make sure they're numeric

      $Self->dmaybedirty('jmailboxes', \%update, {jmailboxid => $jmailboxid});
    }
  }
  if ($t->{modseq} and $Self->{change_cb}) {
    my %map;
    my %dbdata = (jhighestmodseq => $t->{modseq});
    my $state = "$t->{modseq}";
    foreach my $table (keys %{$t->{tables}}) {
      foreach my $group (@{$TABLE2GROUPS{$table}}) {
        $map{$group} = $state;
        $dbdata{"jstate$group"} = $state;
      }
    }

    $Self->dupdate('account', \%dbdata);
    $Self->{change_cb}->($Self, \%map, $state) unless $Self->{t}->{backfilling};
  }

  $Self->{t}{dbh}->commit();
  delete $Self->{t};
}

sub rollback {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  $Self->{t}{dbh}->rollback();
  delete $Self->{t};
}

# handy for error cases
sub reset {
  my $Self = shift;
  return unless $Self->{t};
  $Self->{t}{dbh}->rollback() if $Self->{t}{dbh};
  delete $Self->{t};
}

sub dirty {
  my $Self = shift;
  my $table = shift || die 'need to have a table to dirty';
  unless ($Self->{t}{modseq}) {
    my $user = $Self->get_user();
    $user->{jhighestmodseq}++;
    $Self->{t}{modseq} = $user->{jhighestmodseq};
    $Self->log('debug', "dirty at $user->{jhighestmodseq}");
  }
  $Self->{t}{tables}{$table} = $Self->{t}{modseq};
  return $Self->{t}{modseq};
}

sub get_user {
  my $Self = shift;
  unless ($Self->{t}{user}) {
    $Self->{t}{user} = $Self->dgetone('account');
  }
  # bootstrap
  unless ($Self->{t}{user}) {
    my $data = {
      jhighestmodseq => 1,
    };
    $Self->dinsert('account', $data);
    $Self->{t}{user} = $data;
  }
  return $Self->{t}{user};
}

sub touch_thread_by_msgid {
  my $Self = shift;
  my $msgid = shift;

  my $thrid = $Self->dgetfield('jmessages', { msgid => $msgid }, 'thrid');
  return unless $thrid;

  my $data = $Self->dget('jmessages', { thrid => $thrid, active => 1 });
  unless (@$data) {
    $Self->dmaybedirty('jthreads', {active => 0, data => '[]'}, {thrid => $thrid});
    return;
  }

  my %drafts;
  my @msgs;
  my %seenmsgs;
  foreach my $item (@$data) {
    next unless $item->{isDraft};
    next unless $item->{msginreplyto};  # push the rest of the drafts to the end
    push @{$drafts{$item->{msginreplyto}}}, $item->{msgid};
  }
  foreach my $item (@$data) {
    next if $item->{isDraft};
    push @msgs, $item->{msgid};
    $seenmsgs{$item->{msgid}} = 1;
    next unless $item->{msgmessageid};
    if (my $draftmsgs = $drafts{$item->{msgmessageid}}) {
      push @msgs, @$draftmsgs;
      $seenmsgs{$_} = 1 for @$draftmsgs;
    }
  }
  # make sure unlinked drafts aren't forgotten!
    foreach my $item (@$data) {
    next if $seenmsgs{$item->{msgid}};
    push @msgs, $item->{msgid};
    $seenmsgs{$item->{msgid}} = 1;
  }

  # have to handle doesn't exist case dammit, dmaybdirty isn't good for that
  my $exists = $Self->dgetfield('jthreads', { thrid => $thrid }, 'jcreated');
  if ($exists) {
    $Self->dmaybedirty('jthreads', {active => 1, data => $json->encode(\@msgs)}, {thrid => $thrid});
  }
  else {
    $Self->dmake('jthreads', {thrid => $thrid, data => $json->encode(\@msgs)});
  }
}

sub add_message {
  my $Self = shift;
  my ($data, $mailboxes) = @_;

  return unless @$mailboxes; # no mailboxes, no message

  $Self->dmake('jmessages', {%$data, keywords => $json->encode($data->{keywords})});
  foreach my $mailbox (@$mailboxes) {
    $Self->add_message_to_mailbox($data->{msgid}, $mailbox);
  }
  $Self->touch_thread_by_msgid($data->{msgid});
}

sub update_prefs {
  my $Self = shift;
  my $type = shift;
  my $data = shift;

  my %map = (
    UserPreferences => 'juserprefs',
    ClientPreferences => 'jclientprefs',
    CalendarPreferences => 'jcalendarprefs',
  );

  $Self->begin();
  $Self->dmake($map{$type}, { jprefid => $data->{id}, payload => $json->encode($data) });
  $Self->commit();

  return {};
}

sub update_mailbox_counts {
  my $Self = shift;
  my ($jmailboxid, $jmodseq) = @_;

  die "NOT IN TRANSACTION" unless $Self->{t};
  $Self->{t}{update_mailbox_counts}{$jmailboxid} = $jmodseq;
}

sub add_message_to_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {msgid => $msgid, jmailboxid => $jmailboxid};
  $Self->dmake('jmessagemap', $data);
  $Self->update_mailbox_counts($jmailboxid, $data->{jmodseq});
  $Self->ddirty('jmessages', {}, {msgid => $msgid});
}

sub delete_message_from_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {active => 0};
  $Self->dmaybedirty('jmessagemap', $data, {msgid => $msgid, jmailboxid => $jmailboxid});
  $Self->update_mailbox_counts($jmailboxid, $data->{jmodseq});
  $Self->ddirty('jmessages', {}, {msgid => $msgid});
}

sub change_message {
  my $Self = shift;
  my ($msgid, $data, $newids) = @_;

  my $keywords = $data->{keywords} || {};
  my $bump = $Self->dmaybedirty('jmessages', {
    keywords => $json->encode($keywords),
    isDraft => $keywords->{'$draft'} ? 1 : 0,
    isUnread => $keywords->{'$seen'} ? 0 : 1,
  }, {msgid => $msgid});

  my $oldids = $Self->dgetcol('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid');
  my %old = map { $_ => 1 } @$oldids;

  foreach my $jmailboxid (@$newids) {
    if (delete $old{$jmailboxid}) {
      # just bump the modseq
      $Self->update_mailbox_counts($jmailboxid, $data->{jmodseq}) if $bump;
    }
    else {
      $Self->add_message_to_mailbox($msgid, $jmailboxid);
    }
  }

  foreach my $jmailboxid (keys %old) {
    $Self->delete_message_from_mailbox($msgid, $jmailboxid);
  }
  $Self->touch_thread_by_msgid($msgid);
}

sub get_blob {
  my $Self = shift;
  my $blobId = shift;

  return () unless $blobId =~ m/^([mf])-([^-]+)(?:-(.*))?/;
  my $source = $1;
  my $id = $2;
  my $part = $3;

  if ($source eq 'f') {
    return $Self->get_file($id);
  }
  if ($source eq 'm') {
    return $Self->get_raw_message($id, $part);
  }
}

# NOTE: this can ONLY be used to create draft messages
# RFC 8621 Email/set create validation
sub _validate_email_create {
  my $item = shift;
  my @bad;

  # "headers" property is forbidden — use header:Name instead
  push @bad, 'headers' if exists $item->{headers};

  # Must have body content: bodyStructure OR textBody/htmlBody (not both modes)
  my $has_structure = exists $item->{bodyStructure};
  my $has_bodies = exists $item->{textBody} || exists $item->{htmlBody} || exists $item->{attachments};
  if ($has_structure && $has_bodies) {
    # bodyStructure mode — textBody/htmlBody/attachments are forbidden
    push @bad, 'textBody' if exists $item->{textBody};
    push @bad, 'htmlBody' if exists $item->{htmlBody};
    push @bad, 'attachments' if exists $item->{attachments};
  }

  # textBody and htmlBody must have at most 1 part each
  if ($item->{textBody} && ref($item->{textBody}) eq 'ARRAY' && @{$item->{textBody}} > 1) {
    push @bad, 'textBody';
  }
  if ($item->{htmlBody} && ref($item->{htmlBody}) eq 'ARRAY' && @{$item->{htmlBody}} > 1) {
    push @bad, 'htmlBody';
  }

  # No Content-* headers at top level (but X-Content-* is fine)
  for my $key (keys %$item) {
    if ($key =~ /^header:Content-/i && $key !~ /^header:X-/i) {
      push @bad, $key;
    }
  }

  # No header:Content-Transfer-Encoding on body parts
  for my $partlist ($item->{textBody}, $item->{htmlBody}) {
    next unless $partlist && ref($partlist) eq 'ARRAY';
    for my $part (@$partlist) {
      for my $key (keys %$part) {
        if ($key =~ /^header:Content-Transfer-Encoding$/i) {
          push @bad, $key;
        }
      }
    }
  }
  if ($item->{bodyStructure}) {
    _check_bodystructure_cte($item->{bodyStructure}, 'bodyStructure', \@bad);
  }

  # No duplicate header representations: can't have both convenience
  # property and header:Name for the same header
  my %header_convenience = (
    'message-id' => 'messageId', 'in-reply-to' => 'inReplyTo',
    'references' => 'references', 'sender' => 'sender',
    'from' => 'from', 'to' => 'to', 'cc' => 'cc',
    'bcc' => 'bcc', 'reply-to' => 'replyTo', 'subject' => 'subject',
    'date' => 'sentAt',
  );
  for my $key (keys %$item) {
    next unless $key =~ /^header:([^:]+)(.*)/;
    my $hname = lc $1;
    my $rest = $2;
    if (my $conv = $header_convenience{$hname}) {
      push @bad, $key if exists $item->{$conv};
    }
    # header:Name (no suffix at all) cannot be an array
    if (ref($item->{$key}) eq 'ARRAY' && $rest eq '') {
      push @bad, "header:$1";
    }
  }

  # bodyValues restrictions: isTruncated and isEncodingProblem must not be true
  if ($item->{bodyValues} && ref($item->{bodyValues}) eq 'HASH') {
    for my $partId (keys %{$item->{bodyValues}}) {
      my $bv = $item->{bodyValues}{$partId};
      if ($bv->{isTruncated}) {
        push @bad, "bodyValues/$partId/isTruncated";
      }
      if ($bv->{isEncodingProblem}) {
        push @bad, "bodyValues/$partId/isEncodingProblem";
      }
    }
  }

  # Validate cid values on body parts (no angle brackets, no whitespace)
  for my $partlist ($item->{textBody}, $item->{htmlBody}, $item->{attachments}) {
    next unless $partlist && ref($partlist) eq 'ARRAY';
    for my $part (@$partlist) {
      if (defined $part->{cid} && $part->{cid} =~ /[<>\s]/) {
        push @bad, 'cid';
      }
    }
  }

  # Can't have size with partId (size only valid with blobId)
  for my $partlist ($item->{textBody}, $item->{htmlBody}) {
    next unless $partlist && ref($partlist) eq 'ARRAY';
    for my $part (@$partlist) {
      if (exists $part->{partId} && exists $part->{size}) {
        push @bad, 'size';
      }
    }
  }
  if ($item->{bodyStructure}) {
    _check_bodystructure_size($item->{bodyStructure}, 'bodyStructure', \@bad);
  }

  # headers property forbidden on body parts in bodyStructure
  if ($item->{bodyStructure}) {
    my @parts = (['bodyStructure', $item->{bodyStructure}]);
    while (my $entry = shift @parts) {
      my ($path, $part) = @$entry;
      next unless ref $part eq 'HASH';
      push @bad, "$path/headers" if exists $part->{headers};
      if ($part->{subParts} && ref($part->{subParts}) eq 'ARRAY') {
        my $i = 0;
        for my $sub (@{$part->{subParts}}) {
          push @parts, ["$path/subParts/$i", $sub];
          $i++;
        }
      }
    }
  }

  # headers property forbidden on textBody/htmlBody parts
  for my $partlist ($item->{textBody}, $item->{htmlBody}) {
    next unless $partlist && ref($partlist) eq 'ARRAY';
    for my $part (@$partlist) {
      push @bad, 'headers' if exists $part->{headers};
    }
  }

  return @bad;
}

sub _check_bodystructure_cte {
  my ($part, $path, $bad) = @_;
  return unless ref $part eq 'HASH';
  for my $key (keys %$part) {
    push @$bad, "$path/$key" if $key =~ /^header:Content-Transfer-Encoding$/i;
  }
  if ($part->{subParts} && ref($part->{subParts}) eq 'ARRAY') {
    my $i = 0;
    for my $sub (@{$part->{subParts}}) {
      _check_bodystructure_cte($sub, "$path/subParts/$i", $bad);
      $i++;
    }
  }
}

sub _check_bodystructure_size {
  my ($part, $path, $bad) = @_;
  return unless ref $part eq 'HASH';
  if (exists $part->{partId} && exists $part->{size}) {
    push @$bad, "$path/size";
  }
  if ($part->{subParts} && ref($part->{subParts}) eq 'ARRAY') {
    my $i = 0;
    for my $sub (@{$part->{subParts}}) {
      _check_bodystructure_size($sub, "$path/subParts/$i", $bad);
      $i++;
    }
  }
}

sub _convert_header_value {
  my ($type, $val) = @_;
  if ($type eq 'asText') {
    return $val;
  }
  if ($type eq 'asAddresses') {
    return join(', ', map {
      my $name = $_->{name};
      my $email = $_->{email};
      defined $name && length($name) ? qq{"$name" <$email>} : $email;
    } @$val);
  }
  if ($type eq 'asMessageIds') {
    return join(' ', map { "<$_>" } @$val);
  }
  if ($type eq 'asDate') {
    my $epoch = Date::Parse::str2time($val);
    return Date::Format::time2str("%a, %d %b %Y %H:%M:%S %z", $epoch) if defined $epoch;
    return $val;
  }
  if ($type eq 'asURLs') {
    return join(",\r\n ", map { "<$_>" } @$val);
  }
  return $val;
}

sub _convert_header_forms {
  my ($item) = @_;
  for my $key (keys %$item) {
    next unless $key =~ /^header:([^:]+):(.*)/;
    my $hname = $1;
    my $rest = $2;

    my $val = delete $item->{$key};

    # Parse :asType and :all modifiers
    my $type;
    my $is_all;
    for my $part (split /:/, $rest) {
      if ($part eq 'all') { $is_all = 1 }
      elsif ($part =~ /^as/) { $type = $part }
    }

    if ($type && $is_all && ref($val) eq 'ARRAY') {
      $item->{"header:$hname"} = [map { _convert_header_value($type, $_) } @$val];
    } elsif ($type) {
      $item->{"header:$hname"} = _convert_header_value($type, $val);
    } elsif ($is_all) {
      # :all without type - values are already the text to set
      $item->{"header:$hname"} = $val;
    }
  }
}

sub _convert_header_forms_recursive {
  my ($node) = @_;
  _convert_header_forms($node);
  if ($node->{subParts} && ref($node->{subParts}) eq 'ARRAY') {
    _convert_header_forms_recursive($_) for @{$node->{subParts}};
  }
}

sub create_messages {
  my $Self = shift;
  my $args = shift;
  my $idmap = shift;
  my %created;
  my %notCreated;

  return ({}, {}) unless %$args;

  $Self->begin();

  # XXX - get draft mailbox ID
  my $draftid = $Self->dgetfield('jmailboxes', { role => 'drafts' }, 'jmailboxid');
  my $mailboxdata = $Self->dget('jmailboxes', { active => 1 });
  my %validids = map { $_->{jmailboxid} => 1 } @$mailboxdata;
  my $user_email = ($Self->get_user() || {})->{email};

  $Self->commit();

  my %todo;
  foreach my $cid (keys %$args) {
    my $item = $args->{$cid};
    my $mailboxIds = delete $item->{mailboxIds};
    my $keywords = delete $item->{keywords};

    # RFC 8621 Email/set create validation
    my @bad = _validate_email_create($item);
    if (@bad) {
      $notCreated{$cid} = { type => 'invalidProperties', properties => \@bad };
      next;
    }

    # mailboxIds is required
    unless ($mailboxIds && ref($mailboxIds) eq 'HASH' && keys %$mailboxIds) {
      $notCreated{$cid} = { type => 'invalidProperties', properties => ['mailboxIds'] };
      next;
    }

    $item->{msgdate} ||= time();

    # Validate blob references exist before calling make()
    my @missing_blobs;
    for my $partlist ($item->{textBody}, $item->{htmlBody}, $item->{attachments}) {
      next unless $partlist && ref($partlist) eq 'ARRAY';
      for my $part (@$partlist) {
        next unless $part->{blobId};
        my ($type, $content) = $Self->get_blob($part->{blobId});
        push @missing_blobs, $part->{blobId} unless defined $content;
      }
    }
    if ($item->{bodyStructure}) {
      my @parts = ($item->{bodyStructure});
      while (my $p = shift @parts) {
        next unless ref $p eq 'HASH';
        if ($p->{blobId}) {
          my ($type, $content) = $Self->get_blob($p->{blobId});
          push @missing_blobs, $p->{blobId} unless defined $content;
        }
        push @parts, @{$p->{subParts}} if $p->{subParts} && ref($p->{subParts}) eq 'ARRAY';
      }
    }
    if (@missing_blobs) {
      $notCreated{$cid} = { type => 'blobNotFound', notFound => \@missing_blobs };
      next;
    }

    # Convert typed header forms (header:Name:asType) to raw (header:Name)
    _convert_header_forms($item);
    if ($item->{bodyStructure}) {
      _convert_header_forms_recursive($item->{bodyStructure});
    }

    my %generated_defaults;
    my $defaults_cb = sub {
      my ($name) = @_;
      if (lc($name) eq 'message-id') {
        my $domain = ($user_email && $user_email =~ /\@(.+)/) ? $1 : hostname();
        my $mid = new_uuid_string() . ".$item->{msgdate}\@$domain";
        $generated_defaults{'messageId'} = [$mid];
        return "<$mid>";
      }
      return Data::JSEmail::default_header_defaults($name);
    };

    my $message = eval { Data::JSEmail::make($item, sub { $Self->get_blob(@_) }, $defaults_cb) };
    if ($@ || !$message) {
      $notCreated{$cid} = { type => 'invalidProperties', description => $@ || 'failed to create message' };
      next;
    }
    $todo{$cid} = [$message, $mailboxIds, $keywords, $item->{msgdate}];
  }

  foreach my $cid (keys %todo) {
    my ($message, $mailboxIds, $keywords, $date) = @{$todo{$cid}};
    my @mailboxes = map { $idmap->($_) } keys %$mailboxIds;
    if (grep { not $validids{$_} } @mailboxes) {
      $notCreated{$cid} = { type => 'invalidProperties', properties => ['mailboxIds'] };
      next;
    }
    my ($msgid, $thrid) = $Self->import_message($message, \@mailboxes, $keywords, $date);
    $created{$cid} = {
      id => $msgid,
      threadId => $thrid,
      size => length($message),
      # XXX: other fields to reply
    };
  }

  return (\%created, \%notCreated);
}

sub update_messages {
  my $Self = shift;
  die "Virtual method";
}

sub destroy_messages {
  my $Self = shift;
  die "Virtual method";
}

sub delete_message {
  my $Self = shift;
  my ($msgid) = @_;

  $Self->dmaybedirty('jmessages', {active => 0}, {msgid => $msgid});
  my $oldids = $Self->dgetcol('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid');
  $Self->delete_message_from_mailbox($msgid, $_) for @$oldids;
  $Self->touch_thread_by_msgid($msgid);
}

# returns reported and notFound as a tuple
sub report_messages {
  my $Self = shift;
  my $msgids = shift;
  my $asSpam = shift;

  # XXX - actually report the messages (or at least check that they exist)

  return ($msgids, []);
}

sub parse_event {
  my $Self = shift;
  my $raw = shift;
  my $CalDAV = Net::CalDAVTalk->new(url => 'http://localhost/');  # empty caldav
  my ($event) = $CalDAV->vcalendarToEvents($raw);
  return $event;
}

sub set_event {
  my $Self = shift;
  my $jcalendarid = shift;
  my $event = shift;
  my $eventuid = delete $event->{uid};
  $Self->write_jevent_payload($eventuid, $event);
  if ($Self->dgetfield('jevents', { eventuid => $eventuid }, 'eventuid')) {
    $Self->ddirty('jevents', { active => 1, jcalendarid => $jcalendarid }, { eventuid => $eventuid });
  } else {
    $Self->dmake('jevents', { eventuid => $eventuid, jcalendarid => $jcalendarid });
  }
}

sub delete_event {
  my $Self = shift;
  my $jcalendarid = shift; # doesn't matter
  my $eventuid = shift;
  $Self->unlink_jevent_payload($eventuid);
  return $Self->dmaybedirty('jevents', {active => 0}, {eventuid => $eventuid});
}

sub parse_card {
  my $Self = shift;
  my $raw = shift;
  my $card = vcard_to_jscontact($raw);
  return undef unless $card;

  # Return the JSContact Card directly — callers should migrate
  # to using JSContact properties instead of the old custom format
  return $card;
}

sub set_card {
  my $Self = shift;
  my $jaddressbookid = shift;
  my $card = shift;
  my $carduid = $card->{uid} // '';
  $carduid =~ s/^urn:uuid://;
  my $kind = $card->{kind} // 'individual';
  if ($kind ne 'group') {
    $Self->write_jcontact_payload($carduid, $card);
    if ($Self->dgetfield('jcontacts', { contactuid => $carduid }, 'contactuid')) {
      $Self->ddirty('jcontacts', { active => 1, jaddressbookid => $jaddressbookid }, { contactuid => $carduid });
    } else {
      $Self->dmake('jcontacts', { contactuid => $carduid, jaddressbookid => $jaddressbookid });
    }
  }
  else {
    my $name = $card->{name}{full} // '';
    if ($Self->dgetfield('jcontactgroups', { groupuid => $carduid }, 'groupuid')) {
      $Self->ddirty('jcontactgroups', { active => 1, jaddressbookid => $jaddressbookid, name => $name }, { groupuid => $carduid });
    } else {
      $Self->dmake('jcontactgroups', { groupuid => $carduid, jaddressbookid => $jaddressbookid, name => $name });
    }
    $Self->ddelete('jcontactgroupmap', {groupuid => $carduid});
    foreach my $memberuid (keys %{$card->{members} || {}}) {
      my $uid = $memberuid;
      $uid =~ s/^urn:uuid://;
      $Self->dinsert('jcontactgroupmap', {
        groupuid => $carduid,
        contactuid => $uid,
      });
    }
  }
}

sub delete_card {
  my $Self = shift;
  my $jaddressbookid = shift; # doesn't matter
  my $carduid = shift;
  my $kind = shift;
  if ($kind eq 'contact') {
    $Self->unlink_jcontact_payload($carduid);
    $Self->dmaybedirty('jcontacts', {active => 0}, {contactuid => $carduid, jaddressbookid => $jaddressbookid});
  }
  else {
    $Self->dmaybedirty('jcontactgroups', {active => 0}, {groupuid => $carduid, jaddressbookid => $jaddressbookid});
  }
}

sub put_file {
  my $Self = shift;
  my $accountid = shift;
  my $type = shift;
  my $content = shift;
  my $expires = shift // time() + (7 * 86400);

  # Support passing a filename instead of content
  if (ref $content eq 'HASH' && $content->{file}) {
    my $file = $content->{file};
    open my $fh, '<', $file or die "Cannot open upload file $file: $!";
    local $/;
    $content = <$fh>;
    close $fh;
    unlink $file;
  }

  my $size = length($content);

  $Self->begin();
  my $statement = $Self->dbh->prepare('INSERT OR REPLACE INTO jfiles (type, size, expires) VALUES (?, ?, ?)');
  $statement->bind_param(1, $type);
  $statement->bind_param(2, $size);
  $statement->bind_param(3, $expires);
  $statement->execute();
  my $id = $Self->dbh->last_insert_id(undef, undef, undef, undef);
  $Self->commit();

  $Self->write_upload_blob($id, $content);

  return {
    accountId => "$accountid",
    blobId => "f-$id",
    type => $type,
    expires => Data::JSEmail::isodate($expires),
    size => $size,
  };
}

sub get_file {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->dgetone('jfiles', { jfileid => $id }, 'type');
  $Self->commit();

  return unless $data;

  my $content = $Self->read_upload_blob($id);
  return unless defined $content;
  return ($data->{type}, $content);
}

sub _dbl {
  return '(' . join(', ', map { defined $_ ? "'$_'" : 'NULL' } @_) . ')';
}

sub dinsert {
  my $Self = shift;
  my ($table, $values) = @_;

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my $sql = "INSERT OR REPLACE INTO $table (" . join(', ', @keys) . ") VALUES (" . join (', ', map { "?" } @keys) . ")";

  $Self->log('debug', $sql, _dbl( map { $values->{$_} } @keys));

  $Self->dbh->do($sql, {}, map { $values->{$_} } @keys);

  my $id = $Self->dbh->last_insert_id(undef, undef, undef, undef);
  return $id;
}

# dinsert with a modseq
sub dmake {
  my $Self = shift;
  my ($table, $values, @modseqfields) = @_;
  my $modseq = $Self->dirty($table);
  foreach my $field ('jcreated', 'jmodseq', @modseqfields) {
    $values->{$field} = $modseq;
  }
  $values->{active} = 1;
  return $Self->dinsert($table, $values);
}

sub dupdate {
  my $Self = shift;
  my ($table, $values, $filter) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my @lkeys = $filter ? sort keys %$filter : ();

  my $sql = "UPDATE $table SET " . join (', ', map { "$_ = ?" } @keys);
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl(map { $values->{$_} } @keys), _dbl(map { $filter->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, (map { $values->{$_} } @keys), (map { $filter->{$_} } @lkeys));
}

sub filter_values {
  my $Self = shift;
  my ($table, $values, $filter) = @_;

  # copy so we don't edit the originals
  my %values = $values ? %$values : ();

  my @keys = sort keys %values;
  my @lkeys = $filter ? sort keys %$filter : ();

  my $sql = "SELECT " . join(', ', @keys) . " FROM $table";
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;
  $Self->log('debug', $sql, _dbl(map { $filter->{$_} } @lkeys));
  my $data = $Self->dbh->selectrow_hashref($sql, {}, map { $filter->{$_} } @lkeys);
  foreach my $key (@keys) {
    delete $values{$key} if $filter->{$key}; # in the filter, no point setting again
    delete $values{$key} if ($data->{$key} || '') eq ($values{$key} || '');
  }

  return \%values;
}

sub dmaybeupdate {
  my $Self = shift;
  my ($table, $values, $filter) = @_;

  my $filtered = $Self->filter_values($table, $values, $filter);
  return unless %$filtered;

  return $Self->dupdate($table, $filtered, $filter);
}

# dupdate with a modseq
sub ddirty {
  my $Self = shift;
  my ($table, $values, $filter) = @_;
  $values->{jmodseq} = $Self->dirty($table);
  return $Self->dupdate($table, $values, $filter);
}

sub dmaybedirty {
  my $Self = shift;
  my ($table, $values, $filter, @modseqfields) = @_;

  my $filtered = $Self->filter_values($table, $values, $filter);
  return unless %$filtered;

  my $modseq = $Self->dirty($table);
  foreach my $field ('jmodseq', @modseqfields) {
    $filtered->{$field} = $values->{$field} = $modseq;
  }

  return $Self->dupdate($table, $filtered, $filter);
}

sub dnuke {
  my $Self = shift;
  my ($table, $filter) = @_;

  my $modseq = $Self->dirty($table);

  my @lkeys = sort keys %$filter;
  my $sql = "UPDATE $table SET active = 0, jmodseq = ? WHERE active = 1";
  $sql .= " AND " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl($modseq), _dbl(map { $filter->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, $modseq, map { $filter->{$_} } @lkeys);
}

sub ddelete {
  my $Self = shift;
  my ($table, $filter) = @_;

  my @lkeys = sort keys %$filter;
  my $sql = "DELETE FROM $table";
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl(map { $filter->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, map { $filter->{$_} } @lkeys);
}

sub dget {
  my $Self = shift;
  my ($table, $filter, $fields) = @_;

  $fields ||= '*';

  my @lkeys = sort keys %$filter;
  my @lvals = map { $filter->{$_} } @lkeys;
  my $sql = "SELECT $fields FROM $table";
  $sql .= " WHERE " . join(' AND ', map { ref($filter->{$_}) eq 'ARRAY' ? "$_ $filter->{$_}[0] ?" : "$_ = ?" } @lkeys) if @lkeys;
  $sql .= " ORDER BY $fields" unless ($fields eq '*' or $fields eq 'COUNT(*)');
  my @vals = map { ref($_) eq 'ARRAY' ? $_->[1] : $_ } @lvals;

  $Self->log('debug', $sql, _dbl(@vals));

  return $Self->dbh->selectall_arrayref($sql, {Slice => {}}, @vals);
}

sub dcount {
  my $Self = shift;
  my ($table, $filter) = @_;

  my @lkeys = sort keys %$filter;
  my @lvals = map { $filter->{$_} } @lkeys;
  my $sql = "SELECT COUNT(*) FROM $table";
  $sql .= " WHERE " . join(' AND ', map { ref($filter->{$_}) eq 'ARRAY' ? "$_ $filter->{$_}[0] ?" : "$_ = ?" } @lkeys) if @lkeys;
  my @vals = map { ref($_) eq 'ARRAY' ? $_->[1] : $_ } @lvals;

  $Self->log('debug', $sql, _dbl(@vals));

  return ($Self->dbh->selectrow_array($sql, {}, @vals));
}

sub dgetby {
  my $Self = shift;
  my ($table, $hashkey, $filter, $fields) = @_;
  my $data = $Self->dget($table, $filter, $fields);
  return { map { $_->{$hashkey} => $_ } @$data };
}

sub dgetone {
  my $Self = shift;
  my ($table, $filter, $fields) = @_;

  $fields ||= '*';

  my @lkeys = sort keys %$filter;
  my @lvals = map { $filter->{$_} } @lkeys;
  my $sql = "SELECT $fields FROM $table";
  $sql .= " WHERE " . join(' AND ', map { ref($filter->{$_}) eq 'ARRAY' ? "$_ $filter->{$_}[0] ?" : "$_ = ?" } @lkeys) if @lkeys;
  $sql .= " LIMIT 1";
  my @vals = map { ref($_) eq 'ARRAY' ? $_->[1] : $_ } @lvals;

  $Self->log('debug', $sql, _dbl(map { $filter->{$_} } @lkeys));

  my $data = $Self->dbh->selectall_arrayref($sql, {Slice => {}}, @vals);
  use Data::Dumper;
  $Self->log('debug', Dumper($data));
  return $data->[0];
}

sub dgetfield {
  my $Self = shift;
  my ($table, $filter, $field) = @_;
  my $res = $Self->dgetone($table, $filter, $field);
  return $res ? $res->{$field} : undef;
}

sub dgetcol {
  my $Self = shift;
  my ($table, $filter, $field) = @_;
  my $data = $Self->dget($table, $filter, $field);
  return [ map { $_->{$field} } @$data ];
}

# EmailSubmission query helpers — keep raw SQL in the DB layer.
# $sort is a pre-validated SQL ORDER BY clause (built by API layer from JMAP sort spec).

# Active submissions for EmailSubmission/query.
sub get_submissions {
  my ($Self, $sort) = @_;
  return $Self->dbh->selectall_arrayref(
    "SELECT jsubid,thrid,msgid,sendat FROM jsubmission WHERE active = 1 ORDER BY $sort");
}

# All submissions (including inactive) for EmailSubmission/queryChanges.
sub get_all_submissions {
  my ($Self, $sort) = @_;
  return $Self->dbh->selectall_arrayref(
    "SELECT jsubid,thrid,msgid,sendat,jmodseq,active FROM jsubmission ORDER BY $sort");
}

# Changed submissions since $since_modseq for EmailSubmission/changes.
sub get_submission_changes {
  my ($Self, $since_modseq) = @_;
  return $Self->dbh->selectall_arrayref(
    "SELECT jsubid,thrid,msgid,sendat,jmodseq,active,jcreated FROM jsubmission WHERE jmodseq > ? ORDER BY jmodseq ASC",
    {}, $since_modseq);
}

my $USER_SCHEMA_VERSION = 6;

sub _create_user_tables {
  my ($Self, $dbh) = @_;
  # All CREATE TABLE statements for the current schema version.
  # When bumping $USER_SCHEMA_VERSION, update these to the new target schema
  # and add an incremental migration block in _initdb below.
  # ImapDB overrides this to add IMAP-specific tables after calling SUPER.
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessages (
  msgid TEXT PRIMARY KEY,
  thrid TEXT,
  internaldate INTEGER,
  sha1 TEXT,
  isDraft BOOL,
  isUnread BOOL,
  keywords TEXT,
  msgfrom TEXT,
  msgto TEXT,
  msgcc TEXT,
  msgbcc TEXT,
  msgsubject TEXT,
  msginreplyto TEXT,
  msgmessageid TEXT,
  msgdate INTEGER,
  msgsize INTEGER,
  sortsubject TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jthrid ON jmessages (thrid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS jmsgmessageid ON jmessages (msgmessageid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jthreads (
  thrid TEXT PRIMARY KEY,
  data TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmailboxes (
  jmailboxid TEXT NOT NULL PRIMARY KEY,
  parentId INTEGER,
  role TEXT,
  name TEXT,
  sortOrder INTEGER,
  isSubscribed INTEGER,
  mayReadItems BOOLEAN NOT NULL DEFAULT 1,
  mayAddItems BOOLEAN NOT NULL DEFAULT 1,
  mayRemoveItems BOOLEAN NOT NULL DEFAULT 1,
  maySetSeen BOOLEAN NOT NULL DEFAULT 1,
  maySetKeywords BOOLEAN NOT NULL DEFAULT 1,
  mayCreateChild BOOLEAN NOT NULL DEFAULT 1,
  mayRename BOOLEAN NOT NULL DEFAULT 1,
  mayDelete BOOLEAN NOT NULL DEFAULT 1,
  maySubmit BOOLEAN NOT NULL DEFAULT 1,
  mayAdmin BOOLEAN NOT NULL DEFAULT 1,
  totalEmails INTEGER NOT NULL DEFAULT 0,
  unreadEmails INTEGER NOT NULL DEFAULT 0,
  totalThreads INTEGER NOT NULL DEFAULT 0,
  unreadThreads INTEGER NOT NULL DEFAULT 0,
  jcreated INTEGER,
  jmodseq INTEGER,
  jnoncountsmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessagemap (
  jmailboxid TEXT,
  msgid TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN,
  PRIMARY KEY (jmailboxid, msgid)
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS msgidmap ON jmessagemap (msgid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS account (
  email TEXT,
  displayname TEXT,
  picture TEXT,
  jdeletedmodseq INTEGER NOT NULL DEFAULT 1,
  jhighestmodseq INTEGER NOT NULL DEFAULT 1,
  jstateMailbox TEXT NOT NULL DEFAULT 1,
  jstateThread TEXT NOT NULL DEFAULT 1,
  jstateEmail TEXT NOT NULL DEFAULT 1,
  jstateContact TEXT NOT NULL DEFAULT 1,
  jstateContactGroup TEXT NOT NULL DEFAULT 1,
  jstateCalendar TEXT NOT NULL DEFAULT 1,
  jstateCalendarEvent TEXT NOT NULL DEFAULT 1,
  jstateUserPreferences TEXT NOT NULL DEFAULT 1,
  jstateClientPreferences TEXT NOT NULL DEFAULT 1,
  jstateCalendarPreferences TEXT NOT NULL DEFAULT 1,
  jstateEmailSubmission TEXT NOT NULL DEFAULT 1,
  mtime DATE
);
EOF


  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jrawmessage (
  msgid TEXT PRIMARY KEY,
  hasAttachment INTEGER,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfiles (
  jfileid INTEGER PRIMARY KEY,
  type TEXT,
  size INTEGER,
  expires DATE,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcalendars (
  jcalendarid INTEGER PRIMARY KEY,
  name TEXT,
  color TEXT,
  isVisible BOOLEAN,
  mayReadFreeBusy BOOLEAN,
  mayReadItems BOOLEAN,
  mayAddItems BOOLEAN,
  mayModifyItems BOOLEAN,
  mayRemoveItems BOOLEAN,
  mayDelete BOOLEAN,
  mayRename BOOLEAN,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jevents (
  eventuid TEXT PRIMARY KEY,
  jcalendarid INTEGER,
  firststart DATE,
  lastend DATE,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jeventcal ON jevents (jcalendarid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jaddressbooks (
  jaddressbookid INTEGER PRIMARY KEY,
  name TEXT,
  isVisible BOOLEAN,
  mayReadItems BOOLEAN,
  mayAddItems BOOLEAN,
  mayModifyItems BOOLEAN,
  mayRemoveItems BOOLEAN,
  mayDelete BOOLEAN,
  mayRename BOOLEAN,
  isDefault BOOLEAN DEFAULT 0,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcontactgroups (
  groupuid TEXT PRIMARY KEY,
  jaddressbookid INTEGER,
  name TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jgroupbook ON jcontactgroups (jaddressbookid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcontactgroupmap (
  groupuid TEXT,
  contactuid TEXT,
  mtime DATE,
  PRIMARY KEY (groupuid, contactuid)
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jcontactmap ON jcontactgroupmap (contactuid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcontacts (
  contactuid TEXT PRIMARY KEY,
  jaddressbookid INTEGER,
  isFlagged BOOLEAN,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jcontactbook ON jcontacts (jaddressbookid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jsubmission (
  jsubid INTEGER PRIMARY KEY,
  msgid TEXT,
  thrid TEXT,
  envelope TEXT,
  sendAt INTEGER,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS juserprefs (
  jprefid TEXT PRIMARY KEY,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jclientprefs (
  jprefid TEXT PRIMARY KEY,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcalendarprefs (
  jprefid TEXT PRIMARY KEY,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

}

sub _initdb {
  my $Self = shift;
  my $dbh = shift;

  my ($v) = $dbh->selectrow_array('PRAGMA user_version');

  if ($v == 0) {
    # Fresh install — create full schema at version 1 (the baseline).
    $dbh->begin_work;
    eval {
      $Self->_create_user_tables($dbh);
      $dbh->do("PRAGMA user_version = $USER_SCHEMA_VERSION");
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB init failed: $@" }
    return;
  }

  # Incremental migrations — each in its own transaction, version bumped atomically.
  if ($v < 2) {
    $dbh->begin_work;
    eval {
      # ifolders.myrights: IMAP ACL rights string per folder (RFC 4314).
      # Only present on IMAP account DBs; eval swallows the error on JMAP DBs.
      eval { $dbh->do("ALTER TABLE ifolders ADD COLUMN myrights TEXT") };
      $dbh->do('PRAGMA user_version = 2');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB migration to v2 failed: $@" }
    $v = 2;
  }

  if ($v < 3) {
    $dbh->begin_work;
    eval {
      # iserver.imapSep: IMAP hierarchy separator detected from server namespace.
      eval { $dbh->do("ALTER TABLE iserver ADD COLUMN imapSep TEXT") };
      $dbh->do('PRAGMA user_version = 3');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB migration to v3 failed: $@" }
    $v = 3;
  }

  if ($v < 4) {
    # Cached content columns moved to flat files — drop them from the DB.
    $dbh->begin_work;
    eval {
      eval { $dbh->do("ALTER TABLE jrawmessage DROP COLUMN parsed") };
      eval { $dbh->do("ALTER TABLE jfiles DROP COLUMN content") };
      eval { $dbh->do("ALTER TABLE ievents DROP COLUMN content") };
      eval { $dbh->do("ALTER TABLE icards DROP COLUMN content") };
      $dbh->do('PRAGMA user_version = 4');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB migration to v4 failed: $@" }
    $v = 4;
  }

  if ($v < 5) {
    # JMAP payload columns moved to flat files (jevents/, jcontacts/).
    $dbh->begin_work;
    eval {
      eval { $dbh->do("ALTER TABLE jevents DROP COLUMN payload") };
      eval { $dbh->do("ALTER TABLE jcontacts DROP COLUMN payload") };
      $dbh->do('PRAGMA user_version = 5');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB migration to v5 failed: $@" }
    $v = 5;
  }

  if ($v < 6) {
    # jaddressbooks.isDefault: tracks the default address book per RFC 9610.
    $dbh->begin_work;
    eval {
      eval { $dbh->do("ALTER TABLE jaddressbooks ADD COLUMN isDefault BOOLEAN DEFAULT 0") };
      $dbh->do('PRAGMA user_version = 6');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB migration to v6 failed: $@" }
    $v = 6;
  }
}

1;
