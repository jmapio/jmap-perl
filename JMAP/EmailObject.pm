#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::EmailObject;

use JSON::XS qw(decode_json);
use HTML::Strip;
use Image::Size;
use Email::Address::XS qw(parse_email_groups);
use Email::MIME;
use Email::MIME::Header::AddressList;
use Encode;
use Encode::MIME::Header;
use DateTime;
use Date::Parse;
use MIME::Base64 qw(encode_base64 decode_base64);
use Scalar::Util qw(weaken);
use Digest::SHA;

my $json = JSON::XS->new->utf8->canonical();

sub parse {
  my $rfc822 = shift;
  my $id = Digest::SHA::sha1_hex($rfc822);
  my $eml = Email::MIME->new($rfc822);
  my $res = parse_email($id, $eml);
  $res->{size} = length($rfc822);
  return $res;
}

sub parse_email {
  my $id = shift;
  my $eml = shift;
  my $part = shift;

  my $preview = preview($eml);
  my $headers = headers($eml);

  my %values;
  my $bodystructure = bodystructure(\%values, $id, $eml);
  my $textBody = [];
  my $htmlBody = [];
  my $attachments = [];
  parseStructure([$bodystructure], 'mixed', 0, $textBody, $htmlBody, $attachments);

  my $data = {
    id => $id,
    to => asAddresses($eml->header('To')),
    cc => asAddresses($eml->header('Cc')),
    bcc => asAddresses($eml->header('Bcc')),
    from => asAddresses($eml->header('From')),
    replyTo => asAddresses($eml->header('Reply-To')),
    subject => asText($eml->header('Subject')),
    date => asDate($eml->header('Date')),
    preview => $preview,
    hasAttachment => scalar(@$attachments) ? $JSON::true : $JSON::false,
    headers => $headers,
    bodyStructure => $bodystructure,
    bodyValues => \%values,
    textBody => $textBody,
    htmlBody => $htmlBody,
    attachments => $attachments,
  };

  return $data;
}

sub bodystructure {
  my $values = shift;
  my $id = shift;
  my $eml = shift;
  my $partno = shift;

  my $headers = headers($eml);
  my @parts = $eml->subparts();
  my $type = $eml->content_type() || 'text/plain';
  $type =~ s/;.*//;
  if (@parts) {
    my @sub;
    for (my $n = 1; $n <= @parts; $n++) {
      push @sub, bodystructure($values, $id, $parts[$n-1], $partno ? "$partno.$n" : $n);
    }
    return {
      partId => undef,
      blobId => undef,
      type => lc $type,
      size => 0,
      headers => $headers,
      name => undef,
      cid => undef,
      disposition => 'none',
      subParts => \@sub,
    };
  }
  else {
    $partno ||= '1';
    my $body = $eml->body();
    my $disposition = $eml->header('Content-Disposition') || 'none';
    $disposition =~ s/;.*//;
    return {
      partId => $partno,
      blobId => "m-$id-$partno",
      type => lc $type,
      size => length($body),
      headers => $headers,
      name => $eml->filename(),
      cid => asOneURL($eml->header('Content-Id')),
      language => asCommaList($eml->header('Content-Language')),
      location => asText($eml->header('Content-Location')),
      disposition => $disposition,
    };
    if ($type =~ m{^text/}) {
      $values->{$partno}{value} = $body;
    }
  }
}

# XXX - UTCDate, or?  Maybe need timezone support
sub asDate {
  my $val = shift;
  return eval { isodate(parse_date($val)) };
}

sub asMessageIds {
  my $val = shift;
  return undef unless defined $val;
  $val =~ s/^\s+//;
  $val =~ s/\s+$//;
  my @list = split /\s*,\s*/, $val;
  s/^<// for @list;
  s/>$// for @list;
  return \@list;
}

sub asCommaList {
  my $val = shift;
  return undef unless defined $val;
  $val =~ s/^\s+//;
  $val =~ s/\s+$//;
  my @list = split /\s*,\s*/, $val;
  return \@list;
}

# NOTE: this is totally bogus..
sub asURLs {
  my $val = shift;
  return undef unless defined $val;
  my @list;
  while ($val =~ m/<([^>]+)>/gs) {
    push @list, $1;
  }
  return \@list;
}

sub asOneURL {
  my $val = shift;
  my $list = asURLs($val) || [];
  return $list->[-1];
}

# XXX - more cleaning?
sub asText {
  my $val = shift;
  return undef unless defined $val;
  my $res = encode_utf8(decode('MIME-Header', $val));
  $res =~ s/^\s*//;
  $res =~ s/\s*$//;
  return $res;
}

sub asAddresses {
  my $emails = shift;

  return undef unless defined $emails;
  my $addrs = Email::MIME::Header::AddressList->from_mime_string($emails);
  my @addrs = $addrs->groups();
  my @res;
  while (@addrs) {
    my $group = shift @addrs;
    my $list = shift @addrs;
    if (defined $group) {
      push @res, {
        name => asText($group),
        email => undef,
      };
    }
    foreach my $addr (@$list) {
      my $name = $addr->phrase();
      my $email = $addr->address();
      push @res, {
        name => asText($name),
        email => $email,
      };
    }
    if (defined $group) {
      push @res, {
        name => undef,
        email => undef,
      };
    }
  }

  return \@res;
}

sub headers {
  my $eml = shift;
  my @list = $eml->header_obj->header_raw_pairs();
  my @res;
  while (@list) {
   my $name = shift @list;
   my $value = shift @list;
    push @res, {
      name => $name,
      value => $value,
    };
  }
  return \@res;
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

# XXX: re-define on top of bodyStructure?
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
  my $bs = shift;
  if ($bs->{subParts}) {
    foreach my $sub (@{$bs->{subParts}}) {
      return 1 if hasatt($sub);
    }
  }
  return 1 if $bs->{type} =~ m{(image|video|application)/};  # others?
  return 0;
}

sub isInlineMediaType {
  my $type = shift;
  return 1 if $type =~ m{^image/};
  return 1 if $type =~ m{^audio/};
  return 1 if $type =~ m{^video/};
  return 0;
}

sub parseStructure {
  my $parts = shift;
  my $multipartType = shift;
  my $inAlternative = shift;
  my $textBody = shift;
  my $htmlBody = shift;
  my $attachments = shift;

  my $textLength = $textBody ? @$textBody : -1;
  my $htmlLength = $htmlBody ? @$htmlBody : -1;

  for (my $i = 0; $i < @$parts; $i++) {
    my $part = $parts->[$i];
    my $isMultipart = $part->{type} =~ m{^multipart/(.*)};
    my $subMultiType = $1;
    my $isInline = ($part->{disposition}) ne 'attachment' &&
        # Must be one of the allowed body types
        ( $part->{type} eq 'text/plain' ||
          $part->{type} eq 'text/html' ||
          isInlineMediaType($part->{type}) ) &&
        # If multipart/related, only the first part can be inline
        # If a text part with a filename, and not the first item in the
        # multipart, assume it is an attachment
        ($i == 0 ||
            ( $multipartType ne 'related' &&
                ( isInlineMediaType($part->{type}) || !$part->{name} ) ) );

    if ($isMultipart) {
      parseStructure($part->{subParts}, $subMultiType,
          $inAlternative || ( $subMultiType eq 'alternative' ),
          $htmlBody, $textBody, $attachments);
    }
    elsif ($isInline) {
      if ($multipartType eq 'alternative') {
        if ($part->{type} eq 'text/plain') {
          push @$textBody, $part;
        }
        elsif ($part->{type} eq 'text/html') {
          push @$htmlBody, $part;
        }
        else {
          push @$attachments, $part;
        }
        next;
      }
      elsif ($inAlternative) {
        if ($part->{type} eq 'text/plain') {
          $htmlBody = undef;
        }
        elsif ($part->{type} eq 'text/html') {
          $textBody = undef;
        }
      }
      if ($textBody) {
        push @$textBody, $part;
      }
      if ($htmlBody) {
        push @$htmlBody, $part;
      }
      if ( ( !$textBody || !$htmlBody ) &&
              isInlineMediaType($part->{type}) ) {
        push @$attachments, $part;
      }
    }
    else {
      push @$attachments, $part;
    }
  }

  if ( $multipartType eq 'alternative' && $textBody && $htmlBody ) {
    # Found HTML part only
    if ( $textLength == @$textBody &&
         $htmlLength != @$htmlBody ) {
        push @$textBody, @$htmlBody;
    }
    # found plain text part only
    if ( $htmlLength == @$htmlBody &&
         $textLength != @$textBody ) {
        push @$htmlBody, @$textBody;
    }
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

sub _detect_encoding {
  my $content = shift;
  my $type = shift;

  if ($type =~ m/^message/) {
    if ($content =~ m/[^\x{20}-\x{7f}]/) {
      return '8bit';
    }
    return '7bit';
  }

  if ($type =~ m/^text/) {
    # XXX - also line lengths?
    if ($content =~ m/[^\x{20}-\x{7f}]/) {
      return 'quoted-printable';
    }
    return '7bit';
  }

  return 'base64';
}

sub _makeatt {
  my $Self = shift;
  my $att = shift;

  my %attributes = (
    content_type => $att->{type},
    name => $att->{name},
    filename => $att->{name},
    disposition => $att->{isInline} ? 'inline' : 'attachment',
  );

  my %headers;
  if ($att->{cid}) {
    $headers{'Content-ID'} = "<$att->{cid}>";
  }

  my ($type, $content) = $Self->get_blob($att->{blobId});

  $attributes{encoding} = _detect_encoding($content, $att->{type});

  return Email::MIME->create(
    attributes => \%attributes,
    headers => \%headers,
    body => $content,
  );
}

sub _makemsg {
  my $Self = shift;
  my $args = shift;

  my $header = [
    From => _mkemail($args->{from}),
    To => _mkemail($args->{to}),
    Cc => _mkemail($args->{cc}),
    Bcc => _mkemail($args->{bcc}),
    Subject => $args->{subject},
    Date => Date::Format::time2str("%a, %d %b %Y %H:%M:%S %z", $args->{msgdate}),
    %{$args->{headers} || {}},
  ];
  if ($args->{replyTo}) {
    $header->{'Reply-To'} = _mkemail($args->{replyTo});
  }

  # massive switch
  my $MIME;
  my $htmlpart;
  my $text = $args->{textBody} ? $args->{textBody} : JMAP::DB::htmltotext($args->{htmlBody});
  my $textpart = Email::MIME->create(
    attributes => {
      content_type => 'text/plain',
      charset => 'UTF-8',
    },
    body => Encode::encode_utf8($text),
  );
  if ($args->{htmlBody}) {
    $htmlpart = Email::MIME->create(
      attributes => {
        content_type => 'text/html',
        charset => 'UTF-8',
      },
      body => Encode::encode_utf8($args->{htmlBody}),
    );
  }

  my @attachments = $args->{attachments} ? @{$args->{attachments}} : ();

  if (@attachments) {
    my @attparts = map { $Self->_makeatt($_) } @attachments;
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
        parts => [$msgparts, @attparts],
      );
    }
    else {
      # XXX - attachments
      $MIME = Email::MIME->create(
        header_str => [@$header, 'Content-Type' => 'multipart/mixed'],
        parts => [$textpart, @attparts],
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
  my $idmap = shift;
  my %created;
  my %notCreated;

  return ({}, {}) unless %$args;

  $Self->begin();

  # XXX - get draft mailbox ID
  my $draftid = $Self->dgetfield('jmailboxes', { role => 'drafts' }, 'jmailboxid');

  $Self->commit();

  my %todo;
  foreach my $cid (keys %$args) {
    my $item = $args->{$cid};
    my $mailboxIds = delete $item->{mailboxIds};
    my $keywords = delete $item->{keywords};
    $item->{msgdate} = time();
    $item->{headers}{'Message-ID'} ||= "<" . new_uuid_string() . ".$item->{msgdate}\@$ENV{jmaphost}>";
    my $message = $Self->_makemsg($item);
    # XXX - let's just assume goodness for now - lots of error handling to add
    $todo{$cid} = [$message, $mailboxIds, $keywords];
  }

  foreach my $cid (keys %todo) {
    my ($message, $mailboxIds, $keywords) = @{$todo{$cid}};
    my @mailboxes = map { $idmap->($_) } keys %$mailboxIds;
    my ($msgid, $thrid) = $Self->import_message($message, \@mailboxes, $keywords);
    $created{$cid} = {
      id => $msgid,
      threadId => $thrid,
      size => length($message),
    };
  }

  return (\%created, \%notCreated);
}

sub isodate {
  my $epoch = shift || time();
  my $date = DateTime->from_epoch( epoch => $epoch );
  return $date->iso8601();
}

sub parse_date {
  my $date = shift;
  return str2time($date);
}

1;
