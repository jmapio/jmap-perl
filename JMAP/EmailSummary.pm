#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::EmailSummary;

# An Email's preview and hasAttachment (what a message list asks for) from
# its IMAP BODYSTRUCTURE and the start of one text part, the same values
# Data::JSEmail::parse gives from the whole message.  Pure: the IMAP
# fetches are JMAP::Sync::Common::imap_summary's; this decides what to
# fetch and what the answer is.
#
# hasAttachment: the BODYSTRUCTURE tree is given the shape of a
# Data::JSEmail bodyStructure (type, disposition, name, subParts: all that
# RFC 8621 S4.1.4 parseStructure reads) and Data::JSEmail::parseStructure
# itself classifies it, so the rules are its rules, not a copy of them.
#
# preview: Data::JSEmail::preview takes the first text/plain or text/html
# leaf (depth first) whose preview is not empty.  Each candidate part is
# rebuilt from its own MIME header (BODY[n.MIME]) and body (BODY[n], or
# BODY[TEXT] for a single-part message) and handed to Data::JSEmail::preview,
# so decoding, charsets, HTML stripping and whitespace are its.  Only the
# first $FIRST_WINDOW octets of a part are fetched; when that is cut short
# the cut is made where the decoded text is a prefix of the whole part's
# text, and the answer is kept only when it is already the 256 characters a
# preview is (collapsing a prefix gives a prefix of the collapsed whole).
# Otherwise more is fetched ($SECOND_WINDOW, then the whole part).

use Data::JSEmail ();
use Email::MIME;
use Email::MIME::ContentType ();
use Email::MIME::Encodings ();
use MIME::Base64 ();
use Encode ();

our $FIRST_WINDOW  = 8192;
our $SECOND_WINDOW = 65536;

# Stripped HTML must reach this many characters (collapsed) beyond a
# preview's 256 before a cut-short HTML part is trusted: the cut may fall
# inside an entity or a tag, which only the last few characters can show.
our $HTML_MARGIN = 64;

# The Email::MIME settings Data::JSEmail runs with (Data::JSEmail::_with_settings).
sub _with_settings {
  my $code = shift;
  local $Email::MIME::ContentType::STRICT_PARAMS = 0;
  local $Email::MIME::ContentType::PRE_2231_FORM = 1;
  local $Email::Simple::GROUCHY = 0;
  return $code->(@_);
}

# A parameter of a parsed BODYSTRUCTURE parameter list, RFC 2231 forms
# included (only whether a name is there matters to parseStructure).
sub _param {
  my ($params, $name) = @_;
  return undef unless ref $params eq 'HASH';
  for my $key ($name, "$name*", "${name}*0", "${name}*0*") {
    return $params->{$key} if defined $params->{$key};
  }
  return undef;
}

# The BODYSTRUCTURE (as Mail::IMAPTalk parses it) in the shape of a
# Data::JSEmail bodyStructure, as far as parseStructure looks at it.
sub jmap_tree {
  my $bs = shift;
  if (ref $bs->{'MIME-Subparts'} eq 'ARRAY' && @{$bs->{'MIME-Subparts'}}) {
    return {
      type => 'multipart/' . lc($bs->{'MIME-Subtype'} // ''),
      disposition => undef,
      name => undef,
      subParts => [ map { jmap_tree($_) } @{$bs->{'MIME-Subparts'}} ],
    };
  }
  my $type = lc($bs->{'MIME-Type'} // 'text') . '/' . lc($bs->{'MIME-Subtype'} // 'plain');
  # a multipart that could not be split is one opaque leaf to Data::JSEmail
  $type = 'application/octet-stream' if $type =~ m{^multipart/};
  my $disp = $bs->{'Disposition-Type'};
  $disp = undef if defined $disp && $disp eq '';
  return {
    type => $type,
    disposition => (defined $disp ? lc $disp : undef),
    name => _param($bs->{'Content-Disposition'}, 'filename') // _param($bs->{'Content-Type'}, 'name'),
  };
}

# hasAttachment, as Data::JSEmail::_parse_email decides it.
sub has_attachment {
  my $bs = shift;
  my @attachments;
  Data::JSEmail::parseStructure([jmap_tree($bs)], 'mixed', 0, [], [], \@attachments);
  my ($has) = grep { ($_->{disposition} // '') ne 'inline' } @attachments;
  return $has ? 1 : 0;
}

# The parts Data::JSEmail::preview may take the preview from, in the order
# it tries them: { section, size, top }.  section is the IMAP section of
# the part's body; top is true for a single-part message (whose body is
# BODY[TEXT] and header the message's, and whose preview is final even
# when empty).
sub preview_candidates {
  my $bs = shift;
  my @out;
  my $top = !(ref $bs->{'MIME-Subparts'} eq 'ARRAY' && @{$bs->{'MIME-Subparts'}});
  my $walk;
  $walk = sub {
    my $node = shift;
    if (ref $node->{'MIME-Subparts'} eq 'ARRAY' && @{$node->{'MIME-Subparts'}}) {
      $walk->($_) for @{$node->{'MIME-Subparts'}};
      return;
    }
    my $type = lc($node->{'MIME-Type'} // '') . '/' . lc($node->{'MIME-Subtype'} // '');
    return unless $type eq 'text/plain' || $type eq 'text/html';
    push @out, {
      section => ($top ? 'TEXT' : $node->{'IMAP-Partnum'}),
      size => $node->{Size} // 0,
      top => $top ? 1 : 0,
    };
  };
  $walk->($bs);
  undef $walk;
  return @out;
}

# The FETCH items for a candidate's header (unless $nohdr) and its body
# from octet $start up to $window (to the end when undef), and the keys
# Mail::IMAPTalk answers them under in FullBody mode (a HEADER.FIELDS
# answer is parsed into {headers}).
sub fetch_items {
  my ($cand, $start, $window, $nohdr) = @_;
  my $sec = $cand->{section};
  my $hdr = $nohdr ? undef
    : $cand->{top} ? 'BODY.PEEK[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)]'
    : "BODY.PEEK[$sec.MIME]";
  my $len = defined $window ? $window - $start : 4294967295 - $start;
  my $body = "BODY.PEEK[$sec]" . (($start || defined $window) ? "<$start.$len>" : '');
  return ($hdr, $body, ($cand->{top} ? 'headers' : 'body[' . lc($sec) . '.mime]'), 'body[' . lc($sec) . ']');
}

# A raw header block from Mail::IMAPTalk's parsed {headers} hash.
sub header_from_hash {
  my $h = shift || {};
  my $out = '';
  for my $name (sort keys %$h) {
    $out .= "$name: $_\r\n" for @{$h->{$name}};
  }
  return $out;
}

# Data::JSEmail::preview of a part rebuilt from its header and body; dies
# as it does.
sub _jsemail_preview {
  my ($hdr, $body) = @_;
  return _with_settings(sub {
    my $eml = Data::JSEmail::MIMEPart->new(_join_part($hdr, $body));
    return Data::JSEmail::preview($eml);
  });
}

sub _join_part {
  my ($hdr, $body) = @_;
  $hdr //= '';
  $hdr =~ s/(?:\r?\n)+\z//;
  # a part with no header: one that says nothing about the body
  $hdr = "MIME-Version: 1.0" if $hdr eq '';
  return "$hdr\r\n\r\n$body";
}

# Single-byte charsets: any cut of their octets is a cut between characters.
sub _single_byte {
  my $name = shift;
  return $name =~ /^(?:ascii|ascii-ctrl|iso-8859-\d+|cp12\d\d|cp437|cp850|koi8-\w|MacRoman|null)$/i;
}

# The preview of one candidate part from its MIME header and the first
# octets of its body ($complete when that is all of it).  Returns
#   ('done', $preview)  -- what Data::JSEmail::preview gives for the part
#                          ($preview may be empty or undef)
#   ('more')            -- the part was cut too short to tell
#   ('whole')           -- only the whole part will do
#   ('error', $err)     -- Data::JSEmail::preview died on it
sub part_preview {
  my ($hdr, $body, $complete) = @_;
  $body //= '';

  if ($complete) {
    my $p = eval { _jsemail_preview($hdr, $body) };
    return ('error', $@ || 'failed') if $@;
    return ('done', $p);
  }

  # Cut short: work out the decoded prefix ourselves, at a point where it
  # is a prefix of the whole part's decoded text.
  my $info = eval { _with_settings(sub {
    my $eml = Data::JSEmail::MIMEPart->new(_join_part($hdr, ''));
    my $ctype = $eml->content_type() || 'text/plain';
    my $ct = Email::MIME::ContentType::parse_content_type($eml->header('Content-Type'));
    return {
      ctype => $ctype,
      charset => $ct->{attributes}{charset},
      cte => $eml->header('Content-Transfer-Encoding') // '',
    };
  }) };
  return ('error', $@ || 'failed') unless $info;

  my $kind = $info->{ctype} =~ m{text/plain}i ? 'plain'
           : $info->{ctype} =~ m{text/html}i ? 'html'
           : undef;
  return ('whole') unless $kind;

  # The transfer encoding, read as Email::MIME::body reads it
  my $cte = $info->{cte};
  $cte =~ s/\A\s+//;
  $cte =~ s/\s+\z//;
  $cte =~ s/;.+//;
  my $octets;
  if ($cte eq '' || $cte =~ /\A(?:7bit|8bit|binary)\z/i) {
    $octets = $body;
  }
  elsif ($cte =~ /\Abase64\z/i) {
    (my $b64 = $body) =~ s{[^A-Za-z0-9+/=]}{}g;
    # whole groups of four only, and none past a pad
    $b64 =~ s/=.*\z//s;
    substr($b64, length($b64) - length($b64) % 4) = '';
    $octets = MIME::Base64::decode_base64($b64);
  }
  elsif ($cte =~ /\Aquoted-printable\z/i) {
    # up to the last line break, so no escape or soft break is cut in two
    my $nl = rindex($body, "\n");
    return ('more') if $nl < 0;
    $octets = Email::MIME::Encodings::decode('quoted-printable', substr($body, 0, $nl + 1));
  }
  else {
    return ('whole');
  }

  # A cut between characters of the charset
  my $charset = $info->{charset};
  if (defined $charset) {
    my $enc = Encode::find_encoding($charset);
    return ('whole') unless $enc;   # body_str dies: Data::JSEmail falls back to the raw body
    my $name = $enc->name;
    if ($name =~ /^utf-?8/i) {
      $octets = _utf8_cut($octets);
    }
    elsif (!_single_byte($name)) {
      return ('whole') if $name =~ /UTF-?(?:16|32)|UCS/i;
      my $nl = rindex($octets, "\n");
      return ('more') if $nl < 0;
      $octets = substr($octets, 0, $nl + 1);
    }
    # A prefix that will not decode means the whole part will not either,
    # and then Data::JSEmail previews the undecoded body instead.
    my $copy = $octets;
    return ('whole') unless eval { Encode::decode($charset, $copy, Encode::FB_CROAK()); 1 };
  }

  # The decoded prefix, as an 8bit part of the same type and charset
  (my $h = $hdr // '') =~ s/^Content-Transfer-Encoding:[^\n]*\n(?:[ \t][^\n]*\n)*//gim;
  my $p = eval { _jsemail_preview($h, $octets) };
  return ('more') if $@ || !defined $p || length($p) < 256;
  if ($kind eq 'html') {
    my $text = eval { _with_settings(sub {
      my $eml = Data::JSEmail::MIMEPart->new(_join_part($h, $octets));
      return Data::JSEmail::htmltotext(Data::JSEmail::_body_str($eml));
    }) } // '';
    $text =~ s/\s+/ /gs;
    return ('more') if length($text) < 256 + $HTML_MARGIN;
  }
  return ('done', $p);
}

# The octets with any UTF-8 sequence the end cut in two left off.
sub _utf8_cut {
  my $s = shift;
  my $len = length $s;
  my $j = $len;
  $j-- while $j > 0 && $len - $j < 3 && (ord(substr($s, $j - 1, 1)) & 0xC0) == 0x80;
  return $s if $j == 0;
  my $lead = ord(substr($s, $j - 1, 1));
  if ($lead >= 0xC0) {
    my $need = $lead >= 0xF0 ? 4 : $lead >= 0xE0 ? 3 : 2;
    return substr($s, 0, $j - 1) if $len - ($j - 1) < $need;
  }
  return $s;
}

# A server's RFC 8970 PREVIEW (UTF-8 octets), made a preview the way
# Data::JSEmail makes one (whitespace runs collapsed, 256 characters).
sub normalise_server_preview {
  my $p = shift;
  return undef unless defined $p;
  $p = Encode::decode('UTF-8', $p) unless utf8::is_utf8($p);
  return Data::JSEmail::make_preview($p);
}

# The next window after a 'more' answer, or undef (the whole part).
sub next_window {
  my $window = shift;
  return undef unless defined $window;
  return $SECOND_WINDOW if $window < $SECOND_WINDOW;
  return undef;
}

1;
