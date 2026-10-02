#!/usr/bin/perl
#
# Every method the proxy implements is selected by a capability (RFC 8620 §3.3,
# RFC 9404 §4): a request whose "using" does not list it gets unknownMethod.
# The table in JMAP::Dispatch is the single place that says which, so this
# checks it is complete and that the lookup answers the right way round.

use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

# Every api_ sub in the API modules has an entry.
my %implemented;
for my $file (glob('JMAP/API.pm'), glob('JMAP/API/*.pm')) {
  open my $fh, '<', $file or die "$file: $!";
  while (<$fh>) {
    next unless /^sub api_(\w+?)_(\w+)\b/;
    $implemented{"$1/$2"} = $file;
  }
}
my %tabled = map { $_ => 1 } JMAP::Dispatch::known_methods();
for my $m (sort keys %implemented) {
  ok($tabled{$m}, "$m ($implemented{$m}) is assigned a capability");
}

# The /copy methods the parent orchestrates are there too.
ok($tabled{$_}, "$_ is assigned a capability") for JMAP::Dispatch::copy_methods();

# Lookups.
is_deeply([JMAP::Dispatch::method_capabilities('Email/get')], ['urn:ietf:params:jmap:mail'],
  'Email/get is a mail method');
is_deeply([sort { $a cmp $b } JMAP::Dispatch::method_capabilities('Blob/get')],
  ['urn:ietf:params:jmap:blob', 'urn:ietf:params:jmap:blob2'],
  'Blob/get is selected by either blob capability');
is_deeply([JMAP::Dispatch::method_capabilities('Blob/set')], ['urn:ietf:params:jmap:blob2'],
  'Blob/set only by blob2');
is_deeply([JMAP::Dispatch::method_capabilities('Identity/get')], ['urn:ietf:params:jmap:submission'],
  'Identity lives under submission (RFC 8621 §6)');
is_deeply([JMAP::Dispatch::method_capabilities('Principal/getAvailability')],
  ['urn:ietf:params:jmap:principals:availability'], 'getAvailability has its own capability');
is_deeply([JMAP::Dispatch::method_capabilities('Blob/copy')], ['urn:ietf:params:jmap:core'],
  'Blob/copy is core (RFC 9404 §4)');
is_deeply([JMAP::Dispatch::method_capabilities('No/such')], [], 'unknown method has none');

my $core_mail = { 'urn:ietf:params:jmap:core' => 1, 'urn:ietf:params:jmap:mail' => 1 };
is(JMAP::Dispatch::method_capability_missing('Email/get', $core_mail), undef, 'Email/get allowed with mail');
is_deeply(JMAP::Dispatch::method_capability_missing('Identity/get', $core_mail),
  ['urn:ietf:params:jmap:submission'], 'Identity/get needs submission');
is_deeply(JMAP::Dispatch::method_capability_missing('Blob/upload', $core_mail),
  ['urn:ietf:params:jmap:blob'], 'Blob/upload needs blob');
is(JMAP::Dispatch::method_capability_missing('Blob/get', { 'urn:ietf:params:jmap:blob2' => 1 }), undef,
  'Blob/get allowed with blob2 alone');
is(JMAP::Dispatch::method_capability_missing('No/such', $core_mail), undef,
  'an unknown method is left to the handler');
is_deeply(JMAP::Dispatch::method_capability_missing('Email/get', undef), ['urn:ietf:params:jmap:mail'],
  'no using at all: nothing is allowed');

done_testing;
