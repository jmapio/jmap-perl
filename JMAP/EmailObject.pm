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

my $json = JSON::XS->new->utf8->canonical();

sub parse {
  my $rfc822 = shift;
  my $eml = Email::MIME->new($rfc822);
  return parse_email($eml);
}

sub parse_email {
  my $eml = shift;
  my $part = shift;

  my $preview = preview($eml);
  my $textpart = textpart($eml);
  my $htmlpart = htmlpart($eml);

  my $hasatt = hasatt($eml);
  my $headers = headers($eml);
  my $messages = {};
  my @attachments = attachments($eml, $part, $messages);

  my $data = {
    to => asAddresses($eml->header('To')),
    cc => asAddresses($eml->header('Cc')),
    bcc => asAddresses($eml->header('Bcc')),
    from => asAddresses($eml->header('From')),
    replyTo => asAddresses($eml->header('Reply-To')),
    subject => asText($eml->header('Subject')),
    date => asDate($eml->header('Date')),
    preview => $preview,
    textBody => $textpart,
    htmlBody => $htmlpart,
    hasAttachment => $hasatt,
    headers => $headers,
    attachments => \@attachments,
    attachedEmails => $messages,
  };

  return $data;
}

# XXX - UTCDate, or?  Maybe need timezone support
sub asDate {
  my $val = shift;
  return eval { isodate(parse_date($val)) };
}

sub asMessageIds {
  my $val = shift;
  $val =~ s/^\s+//;
  $val =~ s/\s+$//;
  my @list = split /\s*,\s*/, $val;
  s/^<// for @list;
  s/>$// for @list;
  return \@list;
}

# NOTE: this is totally bogus..
sub asURLs {
  my $val = shift;
  my @list;
  while ($val =~ m/<([^>]+)>/gs) {
    push @list, $1;
  }
  return \@list;
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

sub attachments {
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
      $messages->{$id} = parse_email($sub, $id);
    }
    elsif ($sub->subparts) {
      push @res, attachments($sub, $id, $messages);
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
    my $cid = $sub->header('Content-ID');
    if ($cid and $cid =~ /<(.+)>/) {
      $extra{cid} = "$1";
    }
    push @res, {
      id => $id,
      type => $type,
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
