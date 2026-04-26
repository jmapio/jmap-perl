package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Encode;
use Email::Simple;
use Email::MIME;
use POSIX qw(strftime);

sub api_MDN_send {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user      = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  $Self->commit();

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['identityId']}])
    unless $args->{identityId};

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
    my $notif_to   = $orig_email->header('Disposition-Notification-To')
                  // $orig_email->header('Return-Path')
                  // $orig_email->header('From')
                  // '';

    unless ($notif_to) {
      $notSent{$cid} = { type => 'notFound',
        description => 'Original message has no Disposition-Notification-To header' };
      next;
    }

    my $final_recipient = $mdn->{finalRecipient} // $from_email;
    my $disp         = $mdn->{disposition} || {};
    my $action_mode  = $disp->{actionMode}  // 'manual-action';
    my $sending_mode = $disp->{sendingMode} // 'mdn-sent-manually';
    my $disp_type    = $disp->{type}        // 'displayed';

    my $reporting_ua = $mdn->{reportingUA} // 'JMAP Proxy';
    my $subject  = $mdn->{subject}
      // 'Read: ' . ($orig_email->header('Subject') // '(no subject)');
    my $textbody = $mdn->{textBody}
      // "This is a Message Disposition Notification.\r\n";

    my $boundary  = '=_mdn_' . time() . "_$$";
    my $date      = strftime('%a, %d %b %Y %H:%M:%S %z', localtime);
    my $new_msgid = '<mdn.' . time() . ".$$\@"
      . (($from_email =~ /@(.+)$/)[0] // 'localhost') . '>';

    my $mdn_headers = "Reporting-UA: $reporting_ua\r\n"
      . "Final-Recipient: rfc822;$final_recipient\r\n"
      . ($orig_msgid ? "Original-Message-ID: $orig_msgid\r\n" : '')
      . "Disposition: $action_mode/$sending_mode;$disp_type\r\n";

    my $mdn_rfc822 =
        "From: $from_name <$from_email>\r\n"
      . "To: $notif_to\r\n"
      . "Subject: $subject\r\n"
      . "Date: $date\r\n"
      . "Message-ID: $new_msgid\r\n"
      . "MIME-Version: 1.0\r\n"
      . "Content-Type: multipart/report; report-type=disposition-notification;\r\n"
      . "\tboundary=\"$boundary\"\r\n"
      . "\r\n"
      . "--$boundary\r\n"
      . "Content-Type: text/plain; charset=utf-8\r\n"
      . "\r\n"
      . $textbody . "\r\n"
      . "--$boundary\r\n"
      . "Content-Type: message/disposition-notification\r\n"
      . "\r\n"
      . $mdn_headers . "\r\n"
      . "--$boundary--\r\n";

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

  my $final_recipient = $h{'final-recipient'} // '';
  $final_recipient =~ s/^rfc822;\s*//i;

  my $orig_recipient = $h{'original-recipient'} // '';
  $orig_recipient =~ s/^rfc822;\s*//i;

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
