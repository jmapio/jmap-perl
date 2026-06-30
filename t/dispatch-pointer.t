#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my $data = {
  accountId => 'A',
  list => [ { id => 'x1', sub => { v => 1 } }, { id => 'x2', sub => { v => 2 } } ],
  ids  => ['a','b'],
};

is_deeply([JMAP::Dispatch::resolve_pointer($data, '/accountId')], [1, 'A'], 'plain key');
is_deeply([JMAP::Dispatch::resolve_pointer($data, '/ids')], [1, ['a','b']], 'array value');
is_deeply([JMAP::Dispatch::resolve_pointer($data, '/list/*/id')], [1, ['x1','x2']], 'star maps over array');
is_deeply([JMAP::Dispatch::resolve_pointer($data, '/list/0/sub/v')], [1, 1], 'index then nested');
is((JMAP::Dispatch::resolve_pointer($data, '/missing'))[0], 0, 'missing key fails');
is((JMAP::Dispatch::resolve_pointer($data, '/accountId/x'))[0], 0, 'descend into scalar fails');
is((JMAP::Dispatch::resolve_pointer($data, '/list/*/nope'))[0], 0, 'star over missing subkey fails the whole reference');

done_testing;
