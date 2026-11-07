package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Encode;
use Email::Simple;
use Email::MIME;
use Email::Address::XS;
use POSIX qw(strftime);

sub _is_true_json { my $v = shift; return JSON::is_bool($v) && $v }

# RFC 9007 S2: the Disposition values, each one of a fixed set
my %MDN_DISPOSITION = (
  actionMode  => { map { $_ => 1 } qw(manual-action automatic-action) },
  sendingMode => { map { $_ => 1 } qw(mdn-sent-manually mdn-sent-automatically) },
  type        => { map { $_ => 1 } qw(deleted dispatched displayed processed) },
);

# The client values that become header fields, checked before any of them
# is written: a line break in one would add fields of the client's choosing
# (to the message or to the machine-readable report).
sub _mdn_invalid_properties {
  my ($mdn) = @_;
  my @bad;
  for my $prop (qw(subject reportingUA finalRecipient)) {
    my $v = $mdn->{$prop};
    next unless defined $v;
    push @bad, $prop if ref $v or $v =~ /[\x00-\x1f\x7f]/;
  }
  my $disp = $mdn->{disposition};
  if (ref $disp ne 'HASH') {
    push @bad, 'disposition';
  } else {
    for my $k (sort keys %MDN_DISPOSITION) {
      next unless defined $disp->{$k};
      push @bad, "disposition/$k" unless !ref $disp->{$k} && $MDN_DISPOSITION{$k}{ $disp->{$k} };
    }
  }
  push @bad, 'textBody' if defined $mdn->{textBody} && ref $mdn->{textBody};
  return @bad;
}

# The MDN (RFC 8098 S3): a multipart/report whose first part is the text and
# whose second is the message/disposition-notification fields.  Email::MIME
# encodes the header fields (RFC 2047 for a non-ASCII subject or name), the
# text (quoted-printable, so no line of it can be taken for a boundary) and
# picks the boundary.
sub _mdn_message {
  my (%a) = @_;
  my $fields = '';
  my @f = @{ $a{fields} };
  while (my ($name, $value) = splice(@f, 0, 2)) {
    $fields .= "$name: $value\r\n";
  }
  my $from = Email::Address::XS->new($a{from_name}, $a{from_email})->format;
  my @parts = (
    Email::MIME->create(
      attributes => { content_type => 'text/plain', charset => 'utf-8',
                      encoding => 'quoted-printable' },
      body_str   => $a{text},
    ),
    Email::MIME->create(
      attributes => { content_type => 'message/disposition-notification',
                      encoding => '8bit' },
      body       => Encode::encode_utf8($fields),
    ),
  );
  # Email::MIME->create dates every part; only the message has a Date
  for my $part (@parts) { $part->header_set($_) for qw(Date MIME-Version) }
  my $mime = Email::MIME->create(
    header_str => [
      From         => $from,
      To           => $a{to},
      Subject      => $a{subject},
      Date         => $a{date},
      'Message-ID' => $a{message_id},
    ],
    attributes => { content_type => 'multipart/report' },
    parts      => \@parts,
  );
  $mime->content_type_attribute_set('report-type' => 'disposition-notification');
  return $mime->as_string;
}

sub api_MDN_send {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  $Self->commit();

  # RFC 9007 S2.1: "If the accountId or identityId given cannot be found,
  # the method call is rejected with an invalidArguments error." The
  # account's one Identity is id1 (Identity/get).
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['identityId']}])
    unless ($args->{identityId} // '') eq 'id1';

  # RFC 9007 S2.1: "the server MUST reject an MDN/send that does not result
  # in setting the keyword $mdnsent ... MUST check that the
  # onSuccessUpdateEmail property of the method is correctly set".
  my $osue = $args->{onSuccessUpdateEmail};
  for my $cid (keys %{ $args->{send} || {} }) {
    my $patch = ref $osue eq 'HASH'
      ? ($osue->{"#$cid"} // $osue->{ $Self->idmap($args->{send}{$cid}{forEmailId} // '') })
      : undef;
    my $sets = ref $patch eq 'HASH'
      && ( _is_true_json($patch->{'keywords/$mdnsent'})
        || (ref $patch->{keywords} eq 'HASH' && _is_true_json($patch->{keywords}{'$mdnsent'})) );
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['onSuccessUpdateEmail'],
        description => "onSuccessUpdateEmail must set \$mdnsent on the Email for $cid"}])
      unless $sets;
  }

  my $from_email = $user->{email} // '';
  my $from_name  = $user->{displayname} || $from_email;

  my $send    = $args->{send} || {};
  my %sent;
  my %notSent;

  for my $cid (sort keys %$send) {
    my $mdn = $send->{$cid};

    unless ($mdn->{forEmailId}) {
      $notSent{$cid} = { type => 'invalidProperties', properties => ['forEmailId'] };
      next;
    }
    unless ($mdn->{disposition}) {
      $notSent{$cid} = { type => 'invalidProperties', properties => ['disposition'] };
      next;
    }

    my $emailid = $Self->idmap($mdn->{forEmailId});

    $Self->begin();
    my $msgdata = $Self->{db}->dgetone('jmessages', { msgid => $emailid, active => 1 }, 'msgid,keywords');
    $Self->commit();

    unless ($msgdata) {
      $notSent{$cid} = { type => 'notFound' };
      next;
    }

    my $keywords = decode_json($msgdata->{keywords} // '{}');
    if ($keywords->{'$mdnsent'}) {
      $notSent{$cid} = { type => 'mdnAlreadySent' };
      next;
    }

    my ($ctype, $rfc822) = $Self->{db}->get_raw_message($emailid);
    unless ($rfc822) {
      $notSent{$cid} = { type => 'notFound' };
      next;
    }

    my $orig_email = Email::Simple->new($rfc822);
    my $orig_msgid = $orig_email->header('Message-ID') // '';
    # RFC 9007 S2.1: notFound when the Email "has no valid
    # Disposition-Notification-To header field" -- no falling back to the
    # Return-Path or From, which the recipient never asked to be told
    my $notif_to   = $orig_email->header('Disposition-Notification-To') // '';
    $notif_to =~ s/^\s+|\s+$//g;

    unless ($notif_to =~ /\@/) {
      $notSent{$cid} = { type => 'notFound',
        description => 'Original message has no Disposition-Notification-To header' };
      next;
    }

    # RFC 9007 (and RFC 8098 S3.2.4): finalRecipient keeps its address type,
    # e.g. "rfc822; john@example.com".
    my $final_recipient = $mdn->{finalRecipient} // "rfc822; $from_email";
    $final_recipient = "rfc822; $final_recipient" unless $final_recipient =~ /;/;
    my $disp         = $mdn->{disposition} || {};
    my $action_mode  = $disp->{actionMode}  // 'manual-action';
    my $sending_mode = $disp->{sendingMode} // 'mdn-sent-manually';
    my $disp_type    = $disp->{type}        // 'displayed';

    my $reporting_ua = $mdn->{reportingUA} // 'JMAP Proxy';
    my $subject  = $mdn->{subject}
      // 'Read: ' . ($orig_email->header('Subject') // '(no subject)');
    my $textbody = $mdn->{textBody}
      // "This is a Message Disposition Notification.\r\n";

    if (my @bad = _mdn_invalid_properties($mdn)) {
      $notSent{$cid} = { type => 'invalidProperties', properties => \@bad };
      next;
    }

    my $date      = strftime('%a, %d %b %Y %H:%M:%S %z', localtime);
    my $new_msgid = '<mdn.' . time() . ".$$\@"
      . (($from_email =~ /@(.+)$/)[0] // 'localhost') . '>';

    my $mdn_rfc822 = _mdn_message(
      from_name => $from_name, from_email => $from_email, to => $notif_to,
      subject => $subject, date => $date, message_id => $new_msgid,
      text => $textbody,
      fields => [
        'Reporting-UA'        => $reporting_ua,
        'Final-Recipient'     => $final_recipient,
        ($orig_msgid ? ('Original-Message-ID' => $orig_msgid) : ()),
        'Disposition'         => "$action_mode/$sending_mode;$disp_type",
      ]);

    eval { $Self->{db}->backend_cmd('send_email', $mdn_rfc822, undef) };
    if ($@) {
      my $err = "$@"; $err =~ s/\s+at \S+ line \d+.*//s;
      $notSent{$cid} = { type => 'serverFail', description => $err };
      next;
    }

    $sent{$cid} = {
      forEmailId             => $mdn->{forEmailId},
      subject                => $subject,
      textBody               => $textbody,
      reportingUA            => $reporting_ua,
      disposition            => $disp,
      finalRecipient         => $final_recipient,
      originalMessageId      => $orig_msgid || undef,
      originalRecipient      => undef,
      mdnGateway             => undef,
      includeOriginalMessage => $mdn->{includeOriginalMessage} ? JSON::true : JSON::false,
    };
  }

  my @res = (['MDN/send', {
    accountId => $accountid,
    sent      => %sent    ? \%sent    : undef,
    notSent   => %notSent ? \%notSent : undef,
  }]);

  if ($args->{onSuccessUpdateEmail} && %sent) {
    my %updateEmails;
    for my $cid (keys %sent) {
      my $emailid = $Self->idmap($send->{$cid}{forEmailId});
      my $patch   = $args->{onSuccessUpdateEmail}{"#$cid"}
                 // $args->{onSuccessUpdateEmail}{$emailid};
      $updateEmails{$emailid} = $patch if $patch;
    }
    push @res, $Self->api_Email_set({ update => \%updateEmails }) if %updateEmails;
  }

  return @res;
}

sub _parse_mdn_from_mime {
  my ($mime) = @_;

  my $ct = $mime->content_type // '';
  return undef unless $ct =~ m{multipart/report}i;
  return undef unless $ct =~ m{disposition-notification}i;

  my ($text_part, $mdn_part);
  for my $part ($mime->parts) {
    my $pct = $part->content_type // '';
    if ($pct =~ m{message/disposition-notification}i) {
      $mdn_part = $part;
    }
    elsif (!$text_part && $pct =~ m{text/plain}i) {
      $text_part = $part;
    }
  }
  return undef unless $mdn_part;

  my %h;
  for my $line (split /\r?\n/, $mdn_part->body_raw) {
    if ($line =~ /^([A-Za-z-]+):\s*(.*)$/) {
      $h{lc $1} //= $2;
    }
  }

  # RFC 9007: the recipient fields are returned with their address type.
  my $final_recipient = $h{'final-recipient'} // '';
  my $orig_recipient  = $h{'original-recipient'} // '';

  my $disp_raw = $h{'disposition'} // '';
  my ($modes, $dtype) = split /\s*;\s*/, $disp_raw, 2;
  my ($action_mode, $sending_mode) = split /\s*\/\s*/, $modes // '', 2;
  $_ = lc($_ // '') for ($action_mode, $sending_mode, $dtype);

  return {
    subject           => scalar($mime->header('Subject')),
    textBody          => $text_part ? $text_part->body_str : undef,
    reportingUA       => $h{'reporting-ua'},
    disposition       => {
      actionMode   => $action_mode  || 'manual-action',
      sendingMode  => $sending_mode || 'mdn-sent-manually',
      type         => $dtype        || 'displayed',
    },
    finalRecipient    => $final_recipient    || undef,
    originalMessageId => $h{'original-message-id'} || undef,
    originalRecipient => $orig_recipient     || undef,
    mdnGateway        => $h{'mdn-gateway'}   || undef,
    error             => undef,
    extensionFields   => {},
  };
}

sub api_MDN_parse {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  $Self->commit();

  my %parsed;
  my @notParsable;
  my @notFound;

  for my $blobid (@{$args->{blobIds} || []}) {
    my $content;

    if ($blobid =~ /^f-(\d+)$/) {
      (undef, $content) = $Self->{db}->get_file($1);
    }
    else {
      (undef, $content) = $Self->{db}->get_raw_message($blobid);
    }

    unless (defined $content) {
      push @notFound, $blobid;
      next;
    }

    my $mime = eval { Email::MIME->new($content) };
    my $mdn  = $mime ? _parse_mdn_from_mime($mime) : undef;

    if ($mdn) {
      $parsed{$blobid} = $mdn;
    } else {
      push @notParsable, $blobid;
    }
  }

  return ['MDN/parse', {
    accountId   => $accountid,
    parsed      => %parsed      ? \%parsed      : undef,
    notParsable => @notParsable ? \@notParsable : undef,
    notFound    => @notFound    ? \@notFound    : undef,
  }];
}

1;
