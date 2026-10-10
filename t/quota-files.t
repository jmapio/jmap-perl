#!/usr/bin/perl
# The FileNode quota: an RFC 4331 WebDAV quota as an RFC 9425 Quota object.
use strict;
use warnings;
use Test::More;
use lib '.';
use JSON::XS;
use JMAP::API;

my $q = JMAP::API::_files_quota_to_jmap({ used => 4096, available => 104853504 }, 'user1@example.com');
is_deeply($q, {
  id => 'files:octets', resourceType => 'octets', scope => 'account', name => 'user1@example.com',
  types => ['FileNode'], used => 4096, hardLimit => 104857600,
}, 'used, and a hard limit of used plus available');
like(JSON::XS->new->canonical->encode($q), qr/"hardLimit":104857600,.*"used":4096\b/, 'numbers encode as JSON numbers');
is(JMAP::API::_files_quota_to_jmap(undef, 'x'), undef, 'no WebDAV quota, no Quota object');

done_testing;
