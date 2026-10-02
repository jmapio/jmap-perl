#!/usr/bin/perl
#
# JMAP::BlobConvert is the pure engine behind Blob/get, Blob/upload, Blob/set
# and Blob/convert (RFC 9404 and draft-ietf-jmap-blobext): octets in, octets
# out, with every failure raised as a SetError-shaped hashref. No database.

use strict; use warnings;
use Test::More;
use lib '.';
use Encode ();
use MIME::Base64 ();
use JMAP::BlobConvert;

# ── RFC 9404 §4.2 UTF-8 and digests ─────────────────────────────────────────
is(JMAP::BlobConvert::utf8_text("plain"), 'plain', 'ascii is utf-8 text');
is(JMAP::BlobConvert::utf8_text(Encode::encode('UTF-8', "caf\x{e9}")), "caf\x{e9}", 'multi-octet decodes');
is(JMAP::BlobConvert::utf8_text(substr(Encode::encode('UTF-8', "caf\x{e9}"), 0, 4)), undef,
   'a sequence cut in the middle of a character is not text');
is(JMAP::BlobConvert::utf8_text("\xff\xfe"), undef, 'invalid octets are not text');
is(JMAP::BlobConvert::utf8_text(''), '', 'empty is text');

is(JMAP::BlobConvert::digest('sha-256', 'abc'),
   'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=', 'sha-256 base64');
is(JMAP::BlobConvert::digest('sha', 'abc'), 'qZk+NkcGgWq6PiVxeFDCbJzQ2J0=', 'sha (sha-1) base64');
is(JMAP::BlobConvert::digest('md5', 'abc'), 'kAFQmDzST7DWlj99KOF/cg==', 'md5 base64');
is(JMAP::BlobConvert::digest('nope', 'abc'), undef, 'unknown algorithm is undef');

is(JMAP::BlobConvert::base64_octets('aGVsbG8='), 'hello', 'base64 decodes');
is(JMAP::BlobConvert::base64_octets("aGVs\nbG8="), 'hello', 'whitespace tolerated');
is(JMAP::BlobConvert::base64_octets('aGVsbG8'), undef, 'bad padding rejected');
is(JMAP::BlobConvert::base64_octets('aGV$bG8='), undef, 'bad alphabet rejected');

is(JMAP::BlobConvert::detect_type("\x1f\x8b\x08rest"), 'application/gzip', 'gzip magic');
is(JMAP::BlobConvert::detect_type("PK\x03\x04rest"), 'application/zip', 'zip magic');
is(JMAP::BlobConvert::detect_type("\x89PNG\r\n\x1a\nrest"), 'image/png', 'png magic');
is(JMAP::BlobConvert::detect_type("just text"), undef, 'plain text is unknown');

# ── compress / decompress (blobext §8.5-8.6) ────────────────────────────────
for my $type (JMAP::BlobConvert::compress_types()) {
  my $in = "hello hello hello hello\n" x 50;
  my $z = JMAP::BlobConvert::compress($in, $type, 9, 1);
  ok(length($z) < length($in), "$type compresses");
  is(JMAP::BlobConvert::detect_type($z), $type, "$type output is detected");
  my $r = JMAP::BlobConvert::decompress($z, undef);
  is($r->{content}, $in, "$type roundtrips with auto-detected type");
  ok(!$r->{isIncomplete}, "$type decompression is complete");
  # A truncated stream either yields partial output flagged isIncomplete or,
  # when not even one block decoded, unknownFormat. Never a silent success.
  my $t = eval { JMAP::BlobConvert::decompress(substr($z, 0, int(length($z) / 2)), $type) };
  ok($t ? $t->{isIncomplete} : (ref $@ && $@->{type} eq "unknownFormat"),
     "$type truncated stream is incomplete or unknownFormat");
}
my $e = eval { JMAP::BlobConvert::compress('x', 'application/x-lzip', undef, undef); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'unsupported compression type is invalidProperties');
$e = eval { JMAP::BlobConvert::decompress('not compressed at all', undef); 1 } ? undef : $@;
is($e->{type}, 'unknownFormat', 'undetectable compressed data is unknownFormat');
$e = eval { JMAP::BlobConvert::decompress("\x1f\x8b\x08garbage", 'application/gzip'); 1 } ? undef : $@;
is($e->{type}, 'unknownFormat', 'corrupt gzip with no output is unknownFormat');

# ── archive / extract (blobext §8.2-8.4) ────────────────────────────────────
my @entries = (
  { name => 'site/', entryType => 'directory', modified => '2026-03-01T12:00:00Z', mode => '0755' },
  { name => 'site/index.html', content => '<h1>hi</h1>', modified => '2026-03-01T12:00:00Z', mode => '0644',
    uid => 1000, gid => 1000, ownerName => 'bron', groupName => 'staff' },
  { name => 'site/empty.txt', content => '', modified => '2026-02-15T09:30:00Z' },
);
for my $type (JMAP::BlobConvert::archive_types()) {
  my $a = JMAP::BlobConvert::archive($type, \@entries);
  is(JMAP::BlobConvert::detect_type($a), $type, "$type archive is detected");
  my $x = JMAP::BlobConvert::extract($a, undef);
  is($x->{type}, $type, "$type extract reports the type");
  my %by = map { $_->{name} => $_ } @{ $x->{entries} };
  is($by{'site/index.html'}{content}, '<h1>hi</h1>', "$type file content survives");
  is($by{'site/index.html'}{modified}, '2026-03-01T12:00:00Z', "$type mtime survives");
  is($by{'site/index.html'}{entryType}, 'file', "$type file entryType");
  is($by{'site/'}{entryType}, 'directory', "$type directory entry survives");
  is($by{'site/empty.txt'}{content}, '', "$type empty file is a file with empty content");
  ok(!$x->{isIncomplete}, "$type extraction complete");
  if ($type eq 'application/x-tar') {
    is($by{'site/index.html'}{mode}, '0644', 'tar keeps mode');
    is($by{'site/index.html'}{ownerName}, 'bron', 'tar keeps ownerName');
    is($by{'site/index.html'}{uid}, 1000, 'tar keeps uid');
  }
}
is(JMAP::BlobConvert::archive('application/zip', []), "PK\x05\x06" . ("\x00" x 18), 'empty zip');
is(scalar @{ JMAP::BlobConvert::extract(JMAP::BlobConvert::archive('application/zip', []), 'application/zip')->{entries} },
   0, 'empty zip extracts to no entries') or diag $@;

my $tar = JMAP::BlobConvert::archive('application/x-tar', [
  { name => 'a.txt', content => 'A' },
  { name => 'link', entryType => 'symlink', linkTarget => 'a.txt' },
  { name => 'pipe', entryType => 'fifo' },
]);
my %tx = map { $_->{name} => $_ } @{ JMAP::BlobConvert::extract($tar, 'application/x-tar')->{entries} };
is($tx{link}{entryType}, 'symlink', 'tar symlink entry');
is($tx{link}{linkTarget}, 'a.txt', 'tar symlink target');
is($tx{pipe}{entryType}, 'fifo', 'tar fifo entry');

$e = eval { JMAP::BlobConvert::archive('application/zip', [{ name => 'l', entryType => 'symlink', linkTarget => 'x' }]); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'zip rejects a symlink entry');
$e = eval { JMAP::BlobConvert::archive('application/x-tar', [{ name => 'f' }]); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'a file entry without content is invalidProperties');
$e = eval { JMAP::BlobConvert::archive('application/x-tar', [{ name => 'l', entryType => 'symlink' }]); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'a symlink without linkTarget is invalidProperties');
$e = eval { JMAP::BlobConvert::archive('application/x-tar', [{ name => 'd', entryType => 'directory' }]); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'a directory name must end with /');
$e = eval { JMAP::BlobConvert::archive('application/x-cpio', []); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'unsupported archive type');
$e = eval { JMAP::BlobConvert::extract('definitely not an archive', undef); 1 } ? undef : $@;
is($e->{type}, 'unknownFormat', 'undetectable archive is unknownFormat');

# ── delta / patch (blobext §8.7-8.8) ────────────────────────────────────────
my $base = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n";
my $new  = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n";
my $d = JMAP::BlobConvert::delta($base, $new, 'text/x-diff');
like($d, qr/^\@\@ /m, 'unified diff has a hunk header');
is(JMAP::BlobConvert::patch($base, $d, 'text/x-diff'), $new, 'patch reproduces the new blob');
my $nonl_new = "one\ntwo\nthree-and-no-newline";
my $d2 = JMAP::BlobConvert::delta("one\ntwo\nthree\n", $nonl_new, 'text/x-diff');
is(JMAP::BlobConvert::patch("one\ntwo\nthree\n", $d2, 'text/x-diff'), $nonl_new, 'no newline at end of file handled');
is(JMAP::BlobConvert::patch('', JMAP::BlobConvert::delta('', "new\n", 'text/x-diff'), 'text/x-diff'), "new\n",
   'delta from empty applies');
is(JMAP::BlobConvert::patch("gone\n", JMAP::BlobConvert::delta("gone\n", '', 'text/x-diff'), 'text/x-diff'), '',
   'delta to empty applies');
my $utf = Encode::encode('UTF-8', "caf\x{e9}\n");
is(JMAP::BlobConvert::patch("cafe\n", JMAP::BlobConvert::delta("cafe\n", $utf, 'text/x-diff'), 'text/x-diff'), $utf,
   'non-ascii text survives delta and patch');
$e = eval { JMAP::BlobConvert::patch("different\nbase\n", $d, 'text/x-diff'); 1 } ? undef : $@;
is($e->{type}, 'unknownFormat', 'a delta against another base is unknownFormat');
$e = eval { JMAP::BlobConvert::delta("\xff\xfe", "x", 'text/x-diff'); 1 } ? undef : $@;
is($e->{type}, 'unknownFormat', 'a binary blob cannot be diffed as text');
$e = eval { JMAP::BlobConvert::delta('a', 'b', 'application/x-bsdiff'); 1 } ? undef : $@;
is($e->{type}, 'invalidProperties', 'unsupported delta type');

# ── images ──────────────────────────────────────────────────────────────────
# A 1x1 PNG (the RFC 9404 example image).
my $png = MIME::Base64::decode_base64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAAAXRSTlN/gFy0ywAAAApJREFUeJxjYgAAAAYAAzY3fKgAAAAASUVORK5CYII=');
my $id = JMAP::BlobConvert::image_data($png, 'image/png');
is($id->{width}, 1, 'imageData width');
is($id->{height}, 1, 'imageData height');
is(JMAP::BlobConvert::image_data('text', 'text/plain'), undef, 'imageData is null for a non-image');

my $caps = JMAP::BlobConvert::capabilities();
if ($caps->{supportedImageWriteTypes} && grep { $_ eq 'image/png' } @{ $caps->{supportedImageWriteTypes} }) {
  my ($out, $type) = JMAP::BlobConvert::image_convert($png, { type => 'image/png', width => 1 });
  is($type, 'image/png', 'image converted to png');
  is(JMAP::BlobConvert::detect_type($out), 'image/png', 'converted output is a png');
  if (grep { $_ eq 'image/jpeg' } @{ $caps->{supportedImageWriteTypes} }) {
    my ($j) = JMAP::BlobConvert::image_convert($png, { type => 'image/jpeg', quality => 80, background => '#ffffff' });
    is(JMAP::BlobConvert::detect_type($j), 'image/jpeg', 'png with alpha flattens to jpeg');
  }
}
else {
  diag 'Imager image plugins not installed; image conversion not tested';
  $e = eval { JMAP::BlobConvert::image_convert($png, { type => 'image/png' }); 1 } ? undef : $@;
  is($e->{type}, 'invalidProperties', 'image conversion without support is invalidProperties');
}

done_testing;
