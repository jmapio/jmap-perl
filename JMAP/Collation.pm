package JMAP::Collation;

# The string collations the proxy sorts with (RFC 8620 S5.5 Comparator
# "collation"), named as in the RFC 4790 collation registry.  Pure: no I/O,
# no DB.  t/collation.t covers it.

use strict;
use warnings;
use Encode qw(encode_utf8 decode_utf8);
use Unicode::Normalize qw(NFKD);

# The default when a Comparator names none.  RFC 8620 S5.5: it "MUST be
# unicode-aware" and "SHOULD be case insensitive"; "i;unicode-casemap"
# [RFC5051] is one of the two examples it gives.
our $DEFAULT = 'i;unicode-casemap';

my %KEY = (
  # RFC 4790 S9.3: compare the octets as they are
  'i;octet'           => sub { encode_utf8($_[0]) },
  # RFC 4790 S9.2: map a-z to A-Z, then compare as i;octet
  'i;ascii-casemap'   => sub { encode_utf8($_[0] =~ tr/a-z/A-Z/r) },
  # RFC 5051 S2: map each character by its *simple* titlecase mapping,
  # decompose with NFKD, then compare the UTF-8 as i;octet.  ucfirst gives
  # the full mapping; where that is more than one character (e.g. U+00DF,
  # U+FB01) the simple mapping is the character itself.
  'i;unicode-casemap' => sub {
    encode_utf8(NFKD(join '', map { my $t = ucfirst; length $t == 1 ? $t : $_ } split //, $_[0]));
  },
);

# The collations to advertise in the core capability's collationAlgorithms.
sub supported { return sort keys %KEY }

sub is_supported { return exists $KEY{$_[0] // ''} }

# The sort key for $string under $collation (default $DEFAULT), compared
# with cmp.  $string is characters; a byte string is decoded as UTF-8 first.
sub key {
  my ($collation, $string) = @_;
  $string //= '';
  $string = eval { decode_utf8($string, Encode::FB_CROAK | Encode::LEAVE_SRC) } // $string
    unless utf8::is_utf8($string);
  return $KEY{$collation // $DEFAULT}->($string);
}

# cmp for two strings under the collation a Comparator names.  Pass a hash
# ref as $cache to keep each string's key for the rest of one sort.
sub compare {
  my ($collation, $x, $y, $cache) = @_;
  return key($collation, $x) cmp key($collation, $y) unless $cache;
  $collation //= $DEFAULT;
  my $c = $cache->{$collation} //= {};
  return ($c->{$x // ''} //= key($collation, $x)) cmp ($c->{$y // ''} //= key($collation, $y));
}

1;
