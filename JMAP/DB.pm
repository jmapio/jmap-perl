#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::DB;

use Data::Dumper;
use DBI;
use Carp qw(confess);

use Data::UUID::LibUUID;
use IO::LockedFile;
use JSON::XS qw(encode_json decode_json);
use Email::MIME;
# seriously, it's parsable, get over it
$Email::MIME::ContentType::STRICT_PARAMS = 0;
use HTML::Strip;
use Image::Size;
use Email::Address;
use Encode;
use Encode::MIME::Header;
use DateTime;
use Date::Parse;
use Net::CalDAVTalk;
use Net::CardDAVTalk::VCard;
use MIME::Base64 qw(encode_base64);

my %TABLE2GROUPS = (
  jmessages => ['Messages', 'Threads'],
  jmailboxes => ['Mailboxes'],
  jmessagemap => ['Mailboxes'],
  jrawmessage => [],
  jfiles => [], # for now
  jcalendars => ['Calendars'],
  jevents => ['CalendarEvents'],
  jaddressbooks => [], # not directly
  jcontactgroups => ['ContactGroups'],
  jcontactgroupmap => ['ContactGroups'],
  jcontacts => ['Contacts'],
);

sub new {
  my $class = shift;
  my $accountid = shift || die;
  my $dbh = DBI->connect("dbi:SQLite:dbname=/home/jmap/data/$accountid.sqlite3", undef, undef, { RaiseError => 1 });
  my $Self = bless { accountid => $accountid, dbh => $dbh, start => time() }, ref($class) || $class;
  $Self->_initdb($dbh);
  return $Self;
}

sub delete {
  my $Self = shift;
  my $accountid = $Self->accountid();
  delete $Self->{dbh};
  unlink("/home/jmap/data/$accountid.sqlite3");
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
    #return if $level eq 'debug';
    my $time = time() - $Self->{start};
    warn "[$level $time]: @items\n";
  }
}

sub dbh {
  my $Self = shift;
  return $Self->{dbh};
}

sub in_transaction {
  my $Self = shift;
  return $Self->{t} ? 1 : 0;
}

sub begin {
  my $Self = shift;
  confess("ALREADY IN TRANSACTION") if $Self->{t};
  my $accountid = $Self->accountid();
  $Self->{t} = {};
  # we need this because sqlite locking isn't as robust as you might hope
  $Self->{t}{lock} = IO::LockedFile->new(">/home/jmap/data/$accountid.lock");
  $Self->dbh->begin_work();
}

sub commit {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};

  # push an update if anything to tell..
  my $t = $Self->{t};
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
    $Self->{change_cb}->($Self, \%map);
  }

  $Self->dbh->commit();
  delete $Self->{t};
}

sub rollback {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  $Self->dbh->rollback();
  delete $Self->{t};
}

# handy for error cases
sub reset {
  my $Self = shift;
  return unless $Self->{t};
  $Self->dbh->rollback();
  delete $Self->{t};
}

sub dirty {
  my $Self = shift;
  my $table = shift || die 'need to have a table to dirty';
  confess("NOT IN TRANSACTION") unless $Self->{t};
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
  confess("NOT IN TRANSACTION") unless $Self->{t};
  unless ($Self->{t}{user}) {
    $Self->{t}{user} = $Self->dbh->selectrow_hashref("SELECT * FROM account");
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

sub get_mailboxes {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  unless ($Self->{t}{mailboxes}) {
    $Self->{t}{mailboxes} = $Self->dbh->selectall_hashref("SELECT jmailboxid, jmodseq, label, name, parentId, nummessages, numumessages, numthreads, numuthreads, active FROM jmailboxes", 'jmailboxid', {Slice => {}});
  }
  return $Self->{t}{mailboxes};
}

sub get_mailbox {
  my $Self = shift;
  my $jmailboxid = shift;
  return $Self->get_mailboxes->{$jmailboxid};
}

sub add_mailbox {
  my $Self = shift;
  my ($name, $label, $parentId) = @_;

  my $mailboxes = $Self->get_mailboxes();

  confess("ALREADY EXISTS $name in $parentId") if grep { $_->{name} eq $name and $_->{parentId} == $parentId } values %$mailboxes;

  my $data = {
    name => $name,
    label => $label,
    parentId => $parentId,
    nummessages => 0,
    numthreads => 0,
    numumessages => 0,
    numuthreads => 0,
    active => 1,
  };

  my $id = $data->{jmailboxid} = $Self->dinsert('jmailboxes', $data);
  $Self->{t}{mailboxes}{$id} = $data;

  return $id;
}

sub update_mailbox {
  my $Self = shift;
  my $jmailboxid = shift;
  my $fields = shift;

  my $mailbox = $Self->get_mailbox($jmailboxid);
  confess("INVALID ID $jmailboxid") unless $mailbox;
  confess("NOT ACTIVE $jmailboxid") unless $mailbox->{active};

  foreach my $key (keys %$fields) {
    $mailbox->{$key} = $fields->{$key};
  }

  unless ($mailbox->{active}) {
    # XXX - sanity check all?
    confess("Still messages") if $mailbox->{nummessages};
  }

  $Self->dmaybedirty('jmailboxes', $mailbox, {jmailboxid => $jmailboxid});
}

sub delete_mailbox {
  my $Self = shift;
  my $jmailboxid = shift;
  return $Self->update_mailbox($jmailboxid, {active => 0});
}

sub add_message {
  my $Self = shift;
  my ($data, $mailboxes) = @_;

  return unless @$mailboxes; # no mailboxes, no message

  $Self->dmake('jmessages', $data, $Self->{backfilling});
  foreach my $mailbox (@$mailboxes) {
    $Self->add_message_to_mailbox($data->{msgid}, $mailbox);
  }
}

sub add_message_to_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {msgid => $msgid, jmailboxid => $jmailboxid};
  $Self->dmake('jmessagemap', $data);
  $Self->dmaybeupdate('jmailboxes', {jcountsmodseq => $data->{jmodseq}}, {jmailboxid => $jmailboxid});
}

sub get_raw_message {
  my $Self = shift;
  my $rfc822 = shift;
  my $part = shift;

  return ('message/rfc822', $rfc822) unless $part;

  my $eml = Email::MIME->new($rfc822);
  return find_part($eml, $part);
}

sub add_raw_message {
  my $Self = shift;
  my $msgid = shift;
  my $rfc822 = shift;

  my $eml = Email::MIME->new($rfc822);
  my $message = $Self->parse_message($msgid, $eml);
  my $parsed = encode_json($message);

  # fiddle the top-level fields
  my $data = {
    msgid => $msgid,
    rfc822 => $rfc822,
    parsed => $parsed,
  };

  my $jid = $Self->dinsert('jrawmessage', $data);

  return decode_json($parsed);
}

sub parse_date {
  my $Self = shift;
  my $date = shift;
  return str2time($date);
}

sub isodate {
  my $Selft = shift;
  my $epoch = shift || time();

  my $date = DateTime->from_epoch( epoch => $epoch );
  return $date->iso8601();
}

sub parse_emails {
  my $Self = shift;
  my $emails = shift;

  my @addrs = eval { Email::Address->parse($emails) };
  return map { { name => Encode::decode('MIME-Header', $_->name()), email => $_->address() } } @addrs;
}

sub parse_message {
  my $Self = shift;
  my $messageid = shift;
  my $eml = shift;
  my $part = shift;

  my $preview = preview($eml);
  my $textpart = textpart($eml);
  my $htmlpart = htmlpart($eml);

  my $hasatt = hasatt($eml);
  my $headers = headers($eml);
  my $messages = {};
  my @attachments = $Self->attachments($messageid, $eml, $part, $messages);

  my $data = {
    to => [$Self->parse_emails($eml->header('To'))],
    cc => [$Self->parse_emails($eml->header('Cc'))],
    bcc => [$Self->parse_emails($eml->header('Bcc'))],
    from => [$Self->parse_emails($eml->header('From'))]->[0],
    replyTo => [$Self->parse_emails($eml->header('Reply-To'))]->[0],
    subject => scalar(decode('MIME-Header', $eml->header('Subject'))),
    date => scalar($Self->isodate($Self->parse_date($eml->header('Date')))),
    preview => $preview,
    textBody => $textpart,
    htmlBody => $htmlpart,
    hasAttachment => $hasatt,
    headers => $headers,
    attachments => \@attachments,
    attachedMessages => $messages,
  };

  return $data;
}

sub headers {
  my $eml = shift;
  my $obj = $eml->header_obj();
  my %data;
  foreach my $name ($obj->header_names()) {
    my @values = $obj->header($name);
    $data{$name} = join("\n", @values);
  }
  return \%data;
}

sub find_part {
  my $eml = shift;
  my $target = shift;
  my $part = shift;
  my $num = 0;
  foreach my $sub ($eml->subparts()) {
    $num++;
    my $id = $part ? "$part.$num" : $num;
    my $type = $sub->content_type();
    $type =~ s/;.*//;
    return ($type, $sub->body()) if ($id eq $target);
    if ($type =~ m{^multipart/}) {
      my @res = find_part($sub, $target, $id);
      return @res if @res;
    }
  }
  return ();
}

sub attachments {
  my $Self = shift;
  my $messageid = shift;
  my $eml = shift;
  my $part = shift;
  my $messages = shift;
  my $num = 0;
  my @res;
  foreach my $sub ($eml->subparts()) {
    $num++;
    my $type = $sub->content_type();
    next unless $type;
    my $disposition = $sub->header('Content-Disposition') || 'inline';
    my ($typerest, $disrest) = ('', '');
    if ($type =~ s/;(.*)//) {
      $typerest = $1;
    }
    if ($disposition =~ s/;(.*)//) {
      $disrest = $1;
    }
    my $filename = "unknown";
    if ($disrest =~ m{filename=([^;]+)} || $typerest =~ m{name=([^;]+)}) {
      $filename = $1;
      if ($filename =~ s/^([\'\"])//) {
        $filename =~ s/$1$//;
      }
    }
    my $isInline = $disposition eq 'inline';
    if ($isInline) {
      # these parts, inline, are not attachments
      next if $type =~ m{^text/plain}i;
      next if $type =~ m{^text/html}i;
    }
    my $id = $part ? "$part.$num" : $num;
    if ($type =~ m{^message/rfc822}i) {
      $messages->{$id} = $Self->parse_message($messageid, $sub, $id);
    }
    elsif ($sub->subparts) {
      push @res, $Self->attachments($messageid, $sub, $id, $messages);
      next;
    }
    my $headers = headers($sub);
    my $body = $sub->body();
    my %extra;
    if ($type =~ m{^image/}) {
      my ($w, $h) = imgsize(\$body);
      $extra{width} = $w;
      $extra{height} = $h;
    }
    my $accountid = $Self->accountid();
    push @res, {
      id => $id,
      type => $type,
      url => "https://proxy.jmap.io/raw/$accountid/$messageid/$id/$filename", # XXX dep
      blobId => "$messageid/$id",
      name => $filename,
      size => length($body),
      isInline => $isInline,
      %extra,
    };
  }
  return @res;
}

sub _clean {
  my ($type, $text) = @_;
  #if ($type =~ m/;\s*charset\s*=\s*([^;]+)/) {
    #$text = Encode::decode($1, $text);
  #}
  return $text;
}

sub _body_str {
  my $eml = shift;
  my $str = eval { $eml->body_str() };
  return $str if $str;
  return Encode::decode('us-ascii', $eml->body_raw());
}

sub textpart {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{^text/plain}i) {
    return _clean($type, _body_str($eml));
  }
  foreach my $sub ($eml->subparts()) {
    my $res = textpart($sub);
    return $res if $res;
  }
  return undef;
}

sub htmlpart {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{^text/html}i) {
    return _clean($type, _body_str($eml));
  }
  foreach my $sub ($eml->subparts()) {
    my $res = htmlpart($sub);
    return $res if $res;
  }
  return undef;
}

sub htmltotext {
  my $html = shift;
  my $hs = HTML::Strip->new();
  my $clean_text = $hs->parse( $html );
  $hs->eof;
  return $clean_text;
}

sub preview {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{text/plain}i) {
    my $text = _clean($type, _body_str($eml));
    return make_preview($text);
  }
  if ($type =~ m{text/html}i) {
    my $text = _clean($type, _body_str($eml));
    return make_preview(htmltotext($text));
  }
  foreach my $sub ($eml->subparts()) {
    my $res = preview($sub);
    return $res if $res;
  }
  return undef;
}

sub make_preview {
  my $text = shift;
  $text =~ s/\s+/ /gs;
  return substr($text, 0, 256);
}

sub hasatt {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  return 1 if $type =~ m{(image|video|application)/};
  foreach my $sub ($eml->subparts()) {
    my $res = hasatt($sub);
    return $res if $res;
  }
  return 0;
}

sub delete_message_from_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {active => 0};
  $Self->ddirty('jmessagemap', $data, {msgid => $msgid, jmailboxid => $jmailboxid});
  $Self->dmaybeupdate('jmailboxes', {jcountsmodseq => $data->{jmodseq}}, {jmailboxid => $jmailboxid});
}

sub change_message {
  my $Self = shift;
  my ($msgid, $data, $newids) = @_;

  # doesn't work if only IDs have changed :(
  #return unless $Self->dmaybedirty('jmessages', $data, {msgid => $msgid});

  $Self->ddirty('jmessages', $data, {msgid => $msgid});

  my $oldids = $Self->dbh->selectcol_arrayref("SELECT jmailboxid FROM jmessagemap WHERE msgid = ? AND active = 1", {}, $msgid);
  my %old = map { $_ => 1 } @$oldids;

  foreach my $jmailboxid (@$newids) {
    if (delete $old{$jmailboxid}) {
      # just bump the modseq
      $Self->dmaybeupdate('jmailboxes', {jcountsmodseq => $data->{jmodseq}}, {jmailboxid => $jmailboxid});
    }
    else {
      $Self->add_message_to_mailbox($msgid, $jmailboxid);
    }
  }

  foreach my $jmailboxid (keys %old) {
    $Self->delete_message_from_mailbox($msgid, $jmailboxid);
  }
}

sub _mkone {
  my $h = shift;
  if ($h->{name} ne '') {
    return "\"$h->{name}\" <$h->{email}>";
  }
  else {
    return "$h->{email}";
  }
}

sub _mkemail {
  my $a = shift;
  return join(", ", map { _mkone($_) } @$a);
}

sub _makemsg {
  my $Self = shift;
  my $args = shift;
  my $isDraft = shift;

  my $header = [
    From => _mkone($args->{from}),
    To => _mkemail($args->{to}),
    Cc => _mkemail($args->{cc}),
    Bcc => _mkemail($args->{bcc}),
    Subject => $args->{subject},
    Date => Date::Format::time2str("%a, %d %b %Y %H:%M:%S %z", $args->{msgdate}),
    'Message-Id' => $args->{msgmessageid},
    %{$args->{headers} || {}},
  ];

  # massive switch
  my $MIME;
  my $htmlpart;
  my $text = $args->{textBody} ? $args->{textBody} : JMAP::DB::htmltotext($args->{htmlBody});
  my $textpart = Email::MIME->create(
    attributes => {
      content_type => 'text/plain',
      charset => 'UTF-8',
    },
    body => $text,
  );
  if ($args->{htmlBody}) {
    $htmlpart = Email::MIME->create(
      attributes => {
        content_type => 'text/html',
        charset => 'UTF-8',
      },
      body => $args->{htmlBody},
    );
  }

  my @attachments = $args->{attachments} ? @{$args->{attachments}} : ();

  if (@attachments and not $isDraft) {
    my $encoded = encode_base64(@attachments, '');
    push @$header, "X-JMAP-Draft-Attachments" => $encoded;
    @attachments = ();
  }

  if (@attachments) {
    # most complex case
    if ($htmlpart) {
      my $msgparts = Email::MIME->create(
        attributes => {
          content_type => 'multipart/alternative'
        },
        parts => [$textpart, $htmlpart],
      );
      # XXX - attachments
      $MIME = Email::MIME->create(
        header_str => [@$header, 'Content-Type' => 'multipart/mixed'],
	parts => [$msgparts],
      );
    }
    else {
      # XXX - attachments
      $MIME = Email::MIME->create(
        header_str => [@$header, 'Content-Type' => 'multipart/mixed'],
	parts => [$textpart],
      );
    }
  }
  else {
    if ($htmlpart) {
      $MIME = Email::MIME->create(
        attributes => {
          content_type => 'multipart/alternative',
        },
        header_str => $header,
	parts => [$textpart, $htmlpart],
      );
    }
    else {
      $MIME = Email::MIME->create(
        attributes => {
          content_type => 'text/plain',
          charset => 'UTF-8',
        },
        header_str => $header,
	body => $args->{textBody},
      );
    }
  }

  my $res = $MIME->as_string();
  $res =~ s/\r?\n/\r\n/gs;

  return $res;
}

# NOTE: this can ONLY be used to create draft messages
sub create_messages {
  my $Self = shift;
  my $args = shift;
  my %created;
  my %notCreated;

  my $dbh = $Self->dbh();

  # XXX - get draft mailbox ID
  my ($draftid) = $dbh->selectrow_array("SELECT jmailboxid FROM jmailboxes WHERE role = ?", {}, "drafts");

  foreach my $cid (keys %$args) {
    my $item = $args->{$cid};
    if ($item->{inReplyToMessageId}) {
      my ($replymessageid) = $dbh->selectrow_array("SELECT msgmessageid FROM jmessages WHERE msgid = ?", {}, $item->{inReplyToMessageId});
      unless ($replymessageid) {
        $notCreated{$cid} = 'inReplyToNotFound';
        next;
      }
      $item->{headers}{'In-Reply-To'} = $replymessageid;
      $item->{headers}{'References'} = $replymessageid;
      # XXX - references
    }
    $item->{msgdate} = time();
    $item->{msgmessageid} = new_uuid_string() . '@proxy.jmap.io';
    my $message = $Self->_makemsg($item);
    # XXX - let's just assume goodness for now - lots of error handling to add
    my ($msgid, $thrid) = $Self->import_message($message, [$draftid],
      isUnread => 0,
      isAnswered => 0,
      isFlagged => $args->{isFlagged},
      isDraft => 1,
    );
    $created{$cid} = {
      id => $msgid,
      threadId => $thrid,
      size => length($message),
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

  return $Self->change_message($msgid, {active => 0}, []);
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
  $Self->dmake('jevents', {
    eventuid => $eventuid,
    jcalendarid => $jcalendarid,
    payload => encode_json($event),
  });
}

sub delete_event {
  my $Self = shift;
  my $jcalendarid = shift; # doesn't matter
  my $eventuid = shift;
  return $Self->dupdate('jevents', {active => 0}, {eventuid => $eventuid});
}

sub parse_card {
  my $Self = shift;
  my $raw = shift;
  my ($card) = Net::CardDAVTalk::VCard->new_fromstring($raw);

  my %hash;

  $hash{uid} = $card->uid();
  $hash{kind} = $card->VKind();

  if ($hash{kind} eq 'contact') {
    $hash{lastName} = $card->VLastName();
    $hash{firstName} = $card->VFirstName();
    $hash{prefix} = $card->VTitle();

    $hash{company} = $card->VCompany();
    $hash{department} = $card->VDepartment();

    $hash{emails} = [$card->VEmails()];
    $hash{addresses} = [$card->VAddresses()];
    $hash{phones} = [$card->VPhones()];
    $hash{online} = [$card->VOnline()];
  
    $hash{nickname} = $card->VNickname();
    $hash{birthday} = $card->VBirthday();
    $hash{notes} = $card->VNotes();
  }
  else {
    $hash{name} = $card->VFN();
    $hash{members} = [$card->VGroupContactUIDs()];
  }

  return \%hash;
}

sub set_card {
  my $Self = shift;
  my $jaddressbookid = shift;
  my $card = shift;
  my $carduid = delete $card->{uid};
  my $kind = delete $card->{kind};
  if ($kind eq 'contact') {
    $Self->dmake('jcontacts', {
      contactuid => $carduid,
      jaddressbookid => $jaddressbookid,
      payload => encode_json($card),
    });
  }
  else {
    $Self->dmake('jcontactgroups', {
      groupuid => $carduid,
      jaddressbookid => $jaddressbookid,
      name => $card->{name},
    });
    $Self->ddelete('jcontactgroupmap', {groupuid => $carduid});
    foreach my $item (@{$card->{members}}) {
      $Self->dinsert('jcontactgroupmap', {
        groupuid => $carduid,
        contactuid => $item,
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
    $Self->dupdate('jcontacts', {active => 0}, {contactuid => $carduid, jaddressbookid => $jaddressbookid});
  }
  else {
    $Self->dupdate('jcontactgroups', {active => 0}, {groupuid => $carduid, jaddressbookid => $jaddressbookid});
  }
}

sub create_file {
  my $Self = shift;
  my $type = shift;
  my $content = shift;
  my $expires = shift // time() + (7 * 86400);

  my $size = length($content);

  # XXX - no dedup on sha1 here yet
  my $id = $Self->dinsert('jfiles', { type => $type, size => $size, content => $content, expires => $expires });

  return {
    id => $id,
    type => $type,
    expires => $expires,
    size => $size,
  };
}

sub get_file {
  my $Self = shift;
  my $id = shift;

  my $data = $Self->dbh->selectrow_arrayref("SELECT type,content FROM jfiles WHERE jfileid = ?", {}, $id);

  return @$data;
}

sub _dbl {
  return '(' . join(', ', map { defined $_ ? "'$_'" : 'NULL' } @_) . ')';
}

sub dinsert {
  my $Self = shift;
  my ($table, $values) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

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
  my ($table, $values, $backfilling) = @_;
  $values->{jmodseq} = $backfilling ? 1 : $Self->dirty($table);
  $values->{active} = 1;
  return $Self->dinsert($table, $values);
}

sub dupdate {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my @lkeys = $limit ? sort keys %$limit : ();

  my $sql = "UPDATE $table SET " . join (', ', map { "$_ = ?" } @keys);
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl(map { $values->{$_} } @keys), _dbl(map { $limit->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, (map { $values->{$_} } @keys), (map { $limit->{$_} } @lkeys));
}

sub filter_values {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  # copy so we don't edit the originals
  my %values = $values ? %$values : ();

  my @keys = sort keys %values;
  my @lkeys = $limit ? sort keys %$limit : ();

  my $sql = "SELECT " . join(', ', @keys) . " FROM $table";
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;
  my $data = $Self->dbh->selectrow_hashref($sql, {}, map { $limit->{$_} } @lkeys);
  foreach my $key (@keys) {
    delete $values{$key} if $limit->{$key}; # in the limit, no point setting again
    delete $values{$key} if ($data->{$key} || '') eq ($values{$key} || '');
  }

  return \%values;
}

sub dmaybeupdate {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  my $filtered = $Self->filter_values($table, $values, $limit);
  return unless %$filtered;

  return $Self->dupdate($table, $filtered, $limit);
}

# dupdate with a modseq
sub ddirty {
  my $Self = shift;
  my ($table, $values, $limit) = @_;
  $values->{jmodseq} = $Self->dirty($table);
  return $Self->dupdate($table, $values, $limit);
}

sub dmaybedirty {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  my $filtered = $Self->filter_values($table, $values, $limit);
  return unless %$filtered;

  $filtered->{jmodseq} = $values->{jmodseq} = $Self->dirty($table);
  return $Self->dupdate($table, $filtered, $limit);
}

sub ddelete {
  my $Self = shift;
  my ($table, $limit) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  my @lkeys = sort keys %$limit;
  my $sql = "DELETE FROM $table WHERE " . join(' AND ', map { "$_ = ?" } @lkeys);

  $Self->log('debug', $sql, _dbl(map { $limit->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, map { $limit->{$_} } @lkeys);
}

sub _initdb {
  my $Self = shift;
  my $dbh = shift;

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessages (
  msgid TEXT PRIMARY KEY,
  thrid TEXT,
  internaldate INTEGER,
  sha1 TEXT,
  isUnread BOOLEAN,
  isFlagged BOOLEAN,
  isAnswered BOOLEAN,
  isDraft BOOLEAN,
  msgfrom TEXT,
  msgto TEXT,
  msgcc TEXT,
  msgbcc TEXT,
  msgsubject TEXT,
  msginreplyto TEXT,
  msgmessageid TEXT,
  msgdate INTEGER,
  msgsize INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jthrid ON jmessages (thrid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS jmsgmessageid ON jmessages (msgmessageid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmailboxes (
  jmailboxid INTEGER PRIMARY KEY,
  parentId INTEGER,
  role TEXT,
  name TEXT,
  sortOrder INTEGER,
  mustBeOnlyMailbox BOOLEAN,
  mayReadItems BOOLEAN,
  mayAddItems BOOLEAN,
  mayRemoveItems BOOLEAN,
  mayCreateChild BOOLEAN,
  mayRename BOOLEAN,
  mayDelete BOOLEAN,
  jmodseq INTEGER,
  jcountsmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessagemap (
  jmailboxid INTEGER,
  msgid TEXT,
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
  jdeletedmodseq INTEGER,
  jhighestmodseq INTEGER,
  jstateMailboxes TEXT,
  jstateThreads TEXT,
  jstateMessages TEXT,
  jstateContacts TEXT,
  jstateContactGroups TEXT,
  jstateCalendars TEXT,
  jstateCalendarEvents TEXT,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jrawmessage (
  msgid TEXT PRIMARY KEY,
  rfc822 TEXT,
  parsed TEXT,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfiles (
  jfileid INTEGER PRIMARY KEY,
  type TEXT,
  size INTEGER,
  content TEXT,
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
  payload TEXT,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

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
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

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
  payload TEXT,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

}

1;
