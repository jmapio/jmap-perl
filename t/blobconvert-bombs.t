#!/usr/bin/perl
# A small blob can unpack to far more than it is: decompression, zip and
# pixel bombs are refused (tooLarge, or an image Imager will not allocate)
# rather than unpacked into memory.
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::BlobConvert;
use IO::Compress::Gzip qw(gzip);
use IO::Compress::Bzip2 qw(bzip2);
use IO::Compress::Zip qw(zip);

local $JMAP::BlobConvert::MAX_SIZE_BLOB_SET = 10_000_000;
my $zeros = "\0" x 60_000_000;
my $err = sub { my $code = shift; my $e = eval { $code->(); undef } // $@; ref $e eq 'HASH' ? $e->{type} : "$e" };

gzip(\$zeros => \my $gz);
ok(length $gz < 100_000, 'a gzip bomb is small (' . length($gz) . ' bytes)');
is($err->(sub { JMAP::BlobConvert::decompress($gz, 'application/gzip') }), 'tooLarge', 'gzip bomb: tooLarge');
bzip2(\$zeros => \my $bz);
is($err->(sub { JMAP::BlobConvert::decompress($bz, 'application/x-bzip2') }), 'tooLarge', 'bzip2 bomb: tooLarge');

my $small = "hello world\n" x 1000;
gzip(\$small => \my $sgz);
is(JMAP::BlobConvert::decompress($sgz, 'application/gzip')->{content}, $small, 'an ordinary gzip still unpacks');
my $cut = substr($sgz, 0, length($sgz) - 20);
my $r = JMAP::BlobConvert::decompress($cut, 'application/gzip');
ok($r->{isIncomplete}, "a truncated one is incomplete") or diag explain $r;
is(length $r->{content}, 6721, "with all the content before the break, as before");

zip(\$zeros => \my $zp, Name => 'zeros.bin');
is($err->(sub { JMAP::BlobConvert::extract($zp, 'application/zip') }), 'tooLarge', 'zip bomb: tooLarge');
zip(\$small => \my $szp, Name => 'small.txt');
is(JMAP::BlobConvert::extract($szp, 'application/zip')->{entries}[0]{content}, $small, 'an ordinary zip still extracts');

SKIP: {
  skip 'no Imager', 1 unless $JMAP::BlobConvert::HAVE{Imager};
  skip 'Imager cannot read BMP here', 1 unless grep { $_ eq 'image/bmp' } JMAP::BlobConvert::image_read_types();
  # a 56-byte BMP that says it is 40000 x 40000 pixels
  my $bmp = 'BM' . pack('V', 56) . pack('v2', 0, 0) . pack('V', 54)
          . pack('V', 40) . pack('V', 40000) . pack('V', 40000) . pack('v', 1) . pack('v', 24)
          . pack('V', 0) . pack('V', 0) . pack('V', 2835) . pack('V', 2835) . pack('V', 0) . pack('V', 0) . "\0\0";
  like($err->(sub { JMAP::BlobConvert::image_convert($bmp, { type => 'image/bmp', width => 10 }) }), qr/conversionFailed/,
       'pixel bomb: refused before it is allocated');
}

done_testing;
