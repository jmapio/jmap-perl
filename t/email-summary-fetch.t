#!/usr/bin/perl
#
# Email/get's summary path (preview, hasAttachment) must give what parsing
# the whole message with Data::JSEmail gives, while fetching only the
# BODYSTRUCTURE and the start of one text part (JMAP::Sync::Common::
# imap_summary, JMAP::EmailSummary).
#
# Each message below is answered by a fake IMAP server that serves its
# BODYSTRUCTURE, MIME headers and (partial) part bodies, and the summary is
# compared with Data::JSEmail::parse of the whole message.  With
# CYRUS_IMAP=host:port (and CYRUS_USER, CYRUS_PASS) the same messages are
# also APPENDed to a real server and summarised from there, once without
# the server's PREVIEW (which must be equal) and once with it (which only
# hasAttachment must match: the server makes its own previews; it is used
# only with JMAP_IMAP_USE_PREVIEW=1).

use strict;
use warnings;
use utf8;
use Test::More;
use lib '.';
use Encode ();
use MIME::Base64 ();
use MIME::QuotedPrint ();
use Data::JSEmail;
use JMAP::EmailSummary;
use JMAP::Sync::Common;

my $CRLF = "\r\n";
sub crlf { my $s = shift; $s =~ s/\r?\n/\r\n/g; $s }

sub b64 { my $s = MIME::Base64::encode_base64(shift); crlf($s) }
sub qp  { my $s = MIME::QuotedPrint::encode_qp(shift); crlf($s) }

my $words = join(' ', map { ("lorem", "ipsum", "dolor", "sit", "amet,", "consectetur", "adipiscing", "elit.")[$_ % 8] } 1..400);
my $uwords = join(' ', map { ("naïve", "café", "日本語", "テキスト", "emoji😀", "Ünïcödé", "plain", "€uro")[$_ % 8] } 1..3000);
my $css = "<style type=\"text/css\">\n" . join("\n", map { ".c$_ { color: #123456; margin: 0 auto; padding: 4px; }" } 1..400) . "\n</style>\n";
my $bigcss = "<style>\n" . join("\n", map { ".d$_ { font-family: Helvetica, Arial, sans-serif; }" } 1..3000) . "\n</style>\n";
my $pdf = join('', map { chr(($_ * 7919) % 256) } 1..60000);
my $png = join('', map { chr(($_ * 31) % 256) } 1..3000);

sub msg {
  my ($hdrs, $body) = @_;
  return crlf("From: a\@example.com\nTo: b\@example.com\nSubject: test\nDate: Mon, 2 Nov 2026 10:00:00 +0000\nMessage-ID: <x\@example.com>\nMIME-Version: 1.0\n$hdrs\n\n") . $body;
}

sub multipart {
  my ($type, $boundary, @parts) = @_;
  my $body = "This is a multi-part message in MIME format.\r\n";
  for my $p (@parts) {
    $body .= "\r\n--$boundary\r\n" . $p;
  }
  $body .= "\r\n--$boundary--\r\n";
  return ("Content-Type: multipart/$type; boundary=\"$boundary\"", $body);
}

sub part { my ($hdrs, $body) = @_; crlf("$hdrs\n\n") . $body }

my %messages = (
  'plain short' => msg("Content-Type: text/plain; charset=us-ascii", "Test body.\r\n"),
  'plain no content-type' => msg("X-Foo: bar", "Hello\r\nthere\r\n"),
  'plain empty' => msg("Content-Type: text/plain", ""),
  'plain long 7bit' => msg("Content-Type: text/plain; charset=us-ascii", crlf(join("\n", ($words) x 30))),
  'plain long qp utf-8' => msg("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable",
    qp(Encode::encode_utf8($uwords))),
  'plain long base64 utf-8' => msg("Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64",
    b64(Encode::encode_utf8($uwords))),
  'plain long 8bit utf-8' => msg("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit",
    crlf(Encode::encode_utf8($uwords))),
  'plain long 8bit utf-8 one line' => msg("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit",
    Encode::encode_utf8(("   " x 3000) . $uwords)),
  'plain latin1 qp' => msg("Content-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: quoted-printable",
    qp(Encode::encode('iso-8859-1', "Grüße aus Köln, daß es schön ist. " x 400))),
  'plain shift_jis base64' => msg("Content-Type: text/plain; charset=Shift_JIS\nContent-Transfer-Encoding: base64",
    b64(Encode::encode('shiftjis', crlf(("日本語のテキストです。\n" x 2000))))),
  'plain iso-2022-jp 7bit' => msg("Content-Type: text/plain; charset=ISO-2022-JP\nContent-Transfer-Encoding: 7bit",
    crlf(Encode::encode('iso-2022-jp', ("こんにちは、世界。これはテストです。\n" x 1500)))),
  'plain unknown charset' => msg("Content-Type: text/plain; charset=x-unknown-thing", crlf(join("\n", ($words) x 30))),
  'plain whitespace start' => msg("Content-Type: text/plain", crlf(("\n" x 5000) . "   after a lot of blank lines " . $words)),
  'html with long style head' => msg("Content-Type: text/html; charset=utf-8",
    crlf("<html><head>$css</head><body><p>Hello <b>there</b> &amp; welcome.</p><p>$words</p></body></html>")),
  'html huge style head' => msg("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable",
    qp(Encode::encode_utf8("<html><head>$bigcss</head><body><div>Body text &eacute; $uwords</div></body></html>"))),
  'html minified base64' => msg("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64",
    b64(Encode::encode_utf8("<html><head>$css</head><body>" . join('', map { "<td>$_ $uwords</td>" } 1..3) . "</body></html>" =~ s/\n//gr))),
  'html windows-1252' => msg("Content-Type: text/html; charset=windows-1252",
    crlf(Encode::encode('cp1252', "<html><body><p>“Smart quotes” – and dashes… </p>" . ("<p>$words</p>" x 20) . "</body></html>"))),
  'html short' => msg("Content-Type: text/html", crlf("<html><body><p>Short &amp; sweet</p></body></html>\n")),
);

$messages{'alternative'} = msg(multipart('alternative', 'b1',
  part("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable", qp(Encode::encode_utf8($uwords))),
  part("Content-Type: text/html; charset=utf-8", crlf("<html><body>$words</body></html>"))));

$messages{'alternative empty text'} = msg(multipart('alternative', 'b1',
  part("Content-Type: text/plain; charset=utf-8", ""),
  part("Content-Type: text/html; charset=utf-8", crlf("<html><head>$css</head><body>$words</body></html>"))));

$messages{'mixed with pdf'} = msg(multipart('mixed', 'b2',
  part("Content-Type: text/plain; charset=us-ascii", crlf("See attached.\n")),
  part("Content-Type: application/pdf; name=\"report.pdf\"\nContent-Disposition: attachment; filename=\"report.pdf\"\nContent-Transfer-Encoding: base64", b64($pdf))));

$messages{'mixed attachment first'} = msg(multipart('mixed', 'b2',
  part("Content-Type: application/pdf\nContent-Transfer-Encoding: base64", b64($pdf)),
  part("Content-Type: text/plain", crlf("Text after.\n"))));

{
  my ($ct, $alt) = multipart('alternative', 'b4',
    part("Content-Type: text/plain; charset=utf-8", crlf($words)),
    part("Content-Type: text/html; charset=utf-8", crlf("<p>$words</p>")));
  $messages{'mixed alternative plus attachment'} = msg(multipart('mixed', 'b3',
    part($ct, $alt),
    part("Content-Type: application/octet-stream; name*=utf-8''f%C3%BCr.bin\nContent-Disposition: attachment; filename*=utf-8''f%C3%BCr.bin\nContent-Transfer-Encoding: base64", b64($png))));
}

{
  my ($ct, $rel) = multipart('related', 'b6',
    part("Content-Type: text/html; charset=utf-8", crlf("<html><body><img src=\"cid:img1\"><p>$words</p></body></html>")),
    part("Content-Type: image/png; name=\"logo.png\"\nContent-ID: <img1>\nContent-Disposition: inline; filename=\"logo.png\"\nContent-Transfer-Encoding: base64", b64($png)));
  $messages{'related inline image'} = msg(multipart('alternative', 'b5',
    part("Content-Type: text/plain; charset=utf-8", crlf("Plain version.\n")),
    part($ct, $rel)));
}

$messages{'mixed inline image unnamed'} = msg(multipart('mixed', 'b7',
  part("Content-Type: text/plain", crlf("Look at this:\n")),
  part("Content-Type: image/jpeg\nContent-Disposition: inline\nContent-Transfer-Encoding: base64", b64($png)),
  part("Content-Type: text/plain", crlf("And that.\n"))));

$messages{'text attachment'} = msg(multipart('mixed', 'b8',
  part("Content-Type: text/plain", crlf("Body.\n")),
  part("Content-Type: text/plain; name=\"notes.txt\"\nContent-Disposition: attachment; filename=\"notes.txt\"", crlf("notes\n"))));

$messages{'attached message'} = msg(multipart('mixed', 'b9',
  part("Content-Type: text/plain", crlf("Forwarded:\n")),
  part("Content-Type: message/rfc822", msg("Content-Type: text/plain", crlf("Inner body.\n")))));

$messages{'attached message only'} = msg(multipart('mixed', 'b9',
  part("Content-Type: message/rfc822", msg("Content-Type: text/plain", crlf("Inner body.\n")))));

$messages{'pdf only'} = msg("Content-Type: application/pdf\nContent-Transfer-Encoding: base64", b64($pdf));

$messages{'calendar invite'} = msg(multipart('alternative', 'b10',
  part("Content-Type: text/plain; charset=utf-8", crlf("You are invited.\n")),
  part("Content-Type: text/calendar; method=REQUEST; charset=utf-8", crlf("BEGIN:VCALENDAR\nEND:VCALENDAR\n"))));

# A UTF-8 text cut at every alignment: the windows must never split a
# character, a base64 group or a quoted-printable escape so that it shows.
for my $shift (0..7) {
  my $text = ('x' x $shift) . $uwords;
  $messages{"utf-8 base64 shift $shift"} = msg("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64",
    b64(Encode::encode_utf8($text)));
  $messages{"utf-8 qp shift $shift"} = msg("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable",
    qp(Encode::encode_utf8("<p>" . ('&nbsp;' x ($shift * 300)) . "</p>$text")));
}

# --- a fake IMAP server, answering from the message itself ----------------

{
  package FakeIMAP;
  sub new { my ($class, %a) = @_; bless { caps => {}, bytes => 0, fetches => 0, %a }, $class }
  sub capability { $_[0]{caps} }
  sub examine { 1 }
  sub get_response_code { 42 }
  sub unselect { 1 }
  sub close { 1 }
  sub logout {}

  # IMAPTalk-shaped BODYSTRUCTURE plus every section, from Email::MIME
  sub _walk {
    my ($eml, $partnum, $sections) = @_;
    my $ct = Email::MIME::ContentType::parse_content_type($eml->header('Content-Type'));
    my @sub = lc $ct->{type} eq 'multipart' ? $eml->subparts : ();
    my %ctp = %{$ct->{attributes} || {}};
    if (@sub) {
      my $n = 0;
      return {
        'MIME-Type' => 'multipart', 'MIME-Subtype' => lc $ct->{subtype},
        'MIME-Subparts' => [ map { $n++; _walk($_, ($partnum ? "$partnum.$n" : $n), $sections) } @sub ],
        'Content-Type' => \%ctp, 'Disposition-Type' => '', 'Content-Disposition' => {},
        'IMAP-Partnum' => $partnum // '',
      };
    }
    my $num = $partnum || '1';
    my ($dt, $dp) = ('', {});
    if (my $cd = $eml->header('Content-Disposition')) {
      my $d = Email::MIME::ContentType::parse_content_disposition($cd);
      ($dt, $dp) = (lc $d->{type}, $d->{attributes});
    }
    my $raw = $eml->body_raw;
    if ($partnum) {
      $sections->{"$num.mime"} = $eml->header_obj->as_string . "\r\n";
      $sections->{$num} = $raw;
    }
    my $type = lc $ct->{type};
    $type = 'application' if $type eq 'multipart';
    return {
      'MIME-Type' => $type, 'MIME-Subtype' => lc $ct->{subtype},
      'Content-Type' => \%ctp, 'Content-Transfer-Encoding' => $eml->header('Content-Transfer-Encoding') // '7BIT',
      'Size' => length($raw), 'Disposition-Type' => $dt, 'Content-Disposition' => $dp,
      'IMAP-Partnum' => $num,
    };
  }

  sub fetch {
    my $Self = shift;
    shift if ref $_[0] eq 'HASH';
    my ($uids, $items) = @_;
    $Self->{fetches}++;
    my @uids = ref $uids ? @$uids : split /,/, $uids;
    my %out;
    for my $uid (@uids) {
      my $rfc822 = $Self->{msgs}{$uid} // next;
      my $eml = Data::JSEmail::MIMEPart->new($rfc822);
      my %sections;
      my $bs = _walk($eml, undef, \%sections);
      my $r = $out{$uid} = { uid => $uid };
      if ($items =~ /BODYSTRUCTURE/) {
        $r->{bodystructure} = $bs;
        $Self->{bytes} += 200 + 150 * (() = $rfc822 =~ /^Content-Type:/mgi);
      }
      while ($items =~ /BODY\.PEEK\[([^\]]+)\](?:<(\d+)\.(\d+)>)?/g) {
        my ($sec, $off, $win) = (lc $1, $2, $3);
        my $val;
        if ($sec =~ /^header\.fields/) {
          my %h;
          for my $name ('content-type', 'content-transfer-encoding') {
            my @v = $eml->header_obj->header_raw($name);
            $h{$name} = [ map { s/\r?\n/\r\n/gr } @v ] if @v;
          }
          $r->{headers} = \%h;
          $Self->{bytes} += length(join '', map { @$_ } values %h);
          next;
        }
        elsif ($sec eq 'text') {
          $val = $eml->body_raw;
        }
        else {
          $val = $sections{$sec};
        }
        next unless defined $val;
        $val = length($val) > $off ? substr($val, $off, $win) : "" if defined $win;
        $Self->{bytes} += length $val;
        $Self->{peruid}{$uid} += length $val;
        $r->{"body[$sec]"} = $val;
      }
    }
    return \%out;
  }
}

sub summarise {
  my ($imap) = @_;
  my $backend = bless { auth => {}, imap => $imap }, 'JMAP::Sync::Common';
  my $res = $backend->imap_summary('INBOX', 42, join(',', sort { $a <=> $b } keys %{$imap->{msgs}}));
  delete $backend->{imap};
  return $res->{data};
}

sub want_for {
  my $rfc822 = shift;
  my $p = Data::JSEmail::parse($rfc822, 'x');
  return { preview => $p->{preview}, hasAttachment => ($p->{hasAttachment} ? 1 : 0) };
}

my @names = sort keys %messages;
my %byuid = map { ($_ + 1) => $messages{$names[$_]} } 0..$#names;
my %name = map { ($_ + 1) => $names[$_] } 0..$#names;

{
  my $imap = FakeIMAP->new(msgs => \%byuid);
  my $got = summarise($imap);
  my $total = 0;
  for my $uid (sort { $a <=> $b } keys %byuid) {
    my $want = want_for($byuid{$uid});
    my $g = $got->{$uid};
    ok($g, "$name{$uid}: answered without the whole message") or next;
    is($g->{hasAttachment} ? 1 : 0, $want->{hasAttachment}, "$name{$uid}: hasAttachment");
    is($g->{preview}, $want->{preview}, "$name{$uid}: preview");
    $total += length $byuid{$uid};
  }
  diag("$name{$_}: $imap->{peruid}{$_} of " . length($byuid{$_})) for grep { ($imap->{peruid}{$_}||0) > 20000 } sort keys %{$imap->{peruid}};
  diag(sprintf "fake server: %d messages, %d octets whole, %d fetched for summaries in %d FETCHes",
    scalar(keys %byuid), $total, $imap->{bytes}, $imap->{fetches});
  cmp_ok($imap->{bytes}, '<', $total / 2, 'fetches a small part of the messages');
}

# Without JMAP_IMAP_USE_PREVIEW a server's PREVIEW is not asked for.
{
  my $imap = FakeIMAP->new(msgs => { 1 => $messages{'plain short'} }, caps => { preview => 1 });
  no warnings 'redefine';
  my $orig = \&FakeIMAP::fetch;
  my @items;
  local *FakeIMAP::fetch = sub { push @items, $_[-1]; $orig->(@_) };
  local $ENV{JMAP_IMAP_USE_PREVIEW};
  my $got = summarise($imap);
  ok(!grep({ /PREVIEW/ } @items), 'PREVIEW is not fetched by default');
  is($got->{1}{preview}, 'Test body. ', '... and the preview is our own');
}

# With JMAP_IMAP_USE_PREVIEW, the server's own PREVIEW, where it has one, is used as given (made a
# preview the Data::JSEmail way: whitespace runs collapsed, 256 characters).
{
  local $ENV{JMAP_IMAP_USE_PREVIEW} = 1;
  my $imap = FakeIMAP->new(msgs => { 1 => $messages{'pdf only'} }, caps => { preview => 1 });
  no warnings 'redefine';
  my $orig = \&FakeIMAP::fetch;
  local *FakeIMAP::fetch = sub {
    my $r = $orig->(@_);
    $_->{preview} = Encode::encode_utf8("  Server   préview\r\n") for values %$r;
    return $r;
  };
  my $got = summarise($imap);
  is($got->{1}{preview}, ' Server préview ', 'a server PREVIEW is used, whitespace collapsed');
  ok($got->{1}{hasAttachment}, '... and hasAttachment still comes from BODYSTRUCTURE');
  is($imap->{fetches}, 1, '... in one FETCH');
}

# The pure pieces
is(JMAP::EmailSummary::_utf8_cut("ab\xC3"), "ab", 'utf-8 cut drops a lone lead byte');
is(JMAP::EmailSummary::_utf8_cut("ab\xE2\x82"), "ab", '... and a cut sequence');
is(JMAP::EmailSummary::_utf8_cut("ab\xE2\x82\xAC"), "ab\xE2\x82\xAC", '... and keeps a whole one');
is(JMAP::EmailSummary::_utf8_cut("ab\xF0\x9F\x98"), "ab", '... of four octets too');

# --- against a real server -------------------------------------------------

SKIP: {
  skip 'set CYRUS_IMAP=host:port to run against a real IMAP server', 1 unless $ENV{CYRUS_IMAP};
  require Mail::IMAPTalk;
  my ($host, $port) = split /:/, $ENV{CYRUS_IMAP};
  my $user = $ENV{CYRUS_USER} // 'user1@example.com';
  my $mk = sub {
    Mail::IMAPTalk->new(Server => $host, Port => $port, Username => $user,
      Password => $ENV{CYRUS_PASS} // 'password', UseSSL => 0, UseBlocking => 1) or die "connect: $@";
  };
  my $imap = $mk->();
  my $folder = "summarytest" . $$ . time();
  $imap->create($folder) or die "create $folder: $@";
  for my $uid (sort { $a <=> $b } keys %byuid) {
    $imap->append($folder, { Literal => $byuid{$uid} }) or die "append: $@";
  }
  $imap->examine($folder);
  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;
  my $stored = $imap->fetch('1:*', '(UID RFC822)');
  my %want = map { $stored->{$_}{uid} => want_for($stored->{$_}{rfc822}) } keys %$stored;
  my %uidname = map { $stored->{$_}{uid} => $name{$_} } keys %$stored;
  my $uids = join(',', sort { $a <=> $b } keys %want);

  for my $mode ('own previews', 'server PREVIEW') {
    my $conn = $mk->();
    local $ENV{JMAP_IMAP_USE_PREVIEW} = $mode eq 'server PREVIEW' ? 1 : 0;
    next if $mode eq 'server PREVIEW' && !$conn->capability->{preview};
    my $backend = bless { auth => {}, imap => $conn }, 'JMAP::Sync::Common';
    my $got = $backend->imap_summary($folder, $uidvalidity, $uids)->{data};
    my $diff = 0;
    for my $uid (sort { $a <=> $b } keys %want) {
      my $g = $got->{$uid};
      ok($g, "$mode: $uidname{$uid}: answered") or next;
      is($g->{hasAttachment} ? 1 : 0, $want{$uid}{hasAttachment}, "$mode: $uidname{$uid}: hasAttachment");
      if ($mode eq 'own previews') {
        is($g->{preview}, $want{$uid}{preview}, "$mode: $uidname{$uid}: preview");
      }
      elsif (($g->{preview} // '') ne ($want{$uid}{preview} // '')) {
        $diff++;
        diag("  $uidname{$uid}:\n    got  [" . ($g->{preview}//"undef") . "]\n    want [" . ($want{$uid}{preview}//"undef") . "]") if $ENV{SHOW_DIFF};
      }
    }
    diag("$mode: $diff of " . scalar(keys %want) . " previews differ from Data::JSEmail's") if $mode eq 'server PREVIEW';
  }
  $imap->unselect;
  $imap->delete($folder);
}

done_testing();
