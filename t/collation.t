#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Test::More;
use lib '.';

use JMAP::Collation;

is_deeply([ JMAP::Collation::supported() ],
          [ 'i;ascii-casemap', 'i;octet', 'i;unicode-casemap' ], 'supported collations');
ok(JMAP::Collation::is_supported('i;octet'), 'i;octet is supported');
ok(!JMAP::Collation::is_supported('x-no-such'), 'unknown collation is not');
ok(!JMAP::Collation::is_supported(undef), 'undef is not');

my $cmp = \&JMAP::Collation::compare;

# i;octet: case matters, "B" (0x42) sorts before "a" (0x61)
is($cmp->('i;octet', 'B', 'a'), -1, 'i;octet: B < a');
is($cmp->('i;octet', 'a', 'A'), 1, 'i;octet: a > A');

# i;ascii-casemap: ASCII case folded, nothing else
is($cmp->('i;ascii-casemap', 'a', 'A'), 0, 'i;ascii-casemap: a == A');
is($cmp->('i;ascii-casemap', 'a', 'B'), -1, 'i;ascii-casemap: a < B');
isnt($cmp->('i;ascii-casemap', 'é', 'É'), 0, 'i;ascii-casemap: é != É');

# i;unicode-casemap (RFC 5051): Unicode case folded, compatibility-decomposed
is($cmp->('i;unicode-casemap', 'é', 'É'), 0, 'i;unicode-casemap: é == É');
is($cmp->('i;unicode-casemap', "e\x{301}", 'é'), 0, 'i;unicode-casemap: decomposed é == é');
is($cmp->('i;unicode-casemap', "\x{216B}", 'xii'), 0, 'i;unicode-casemap: roman numeral twelve == xii');
isnt($cmp->('i;unicode-casemap', "\x{FB01}", 'FI'), 0, 'i;unicode-casemap: simple titlecase leaves the fi ligature');
is($cmp->('i;unicode-casemap', 'apple', 'Banana'), -1, 'i;unicode-casemap: apple < Banana');

# the default is i;unicode-casemap
is($cmp->(undef, 'apple', 'Banana'), -1, 'default is case insensitive');

# UTF-8 bytes are decoded first, so stored names compare like characters
is($cmp->(undef, Encode::encode_utf8('Éclair'), 'éclair'), 0, 'UTF-8 bytes decoded');

done_testing;
