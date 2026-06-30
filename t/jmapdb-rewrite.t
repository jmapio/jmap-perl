#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

my $dir;
BEGIN { require File::Temp; $dir = File::Temp::tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

my $calls = [
  ['Email/get', { accountId => 'user1', ids => ['m1'] }, '0'],
  ['Email/set', {
      accountId => 'user1',
      create    => { k => { from => [{ email => 'user1@example.com', name => 'user1' }] } },
  }, '1'],
  ['Email/copy', { fromAccountId => 'user1', toAccountId => 'user1', create => {} }, '2'],
  ['Foo/echo', 'not-a-hash', '9'],
  ['Email/get', { accountId => 'other_user', ids => ['m9'] }, '10'],
];

JMAP::JmapDB::_rewrite_method_ids($calls, 'user1', 'backend99');

is($calls->[0][1]{accountId}, 'backend99', 'Email/get accountId rewritten');
is($calls->[1][1]{accountId}, 'backend99', 'Email/set accountId rewritten');
is($calls->[1][1]{create}{k}{from}[0]{email}, 'user1@example.com',
   'email address in body is NOT corrupted');
is($calls->[1][1]{create}{k}{from}[0]{name}, 'user1',
   'name field in body is NOT corrupted');
is($calls->[2][1]{fromAccountId}, 'backend99', 'fromAccountId rewritten');
is($calls->[2][1]{toAccountId},   'backend99', 'toAccountId rewritten');
is($calls->[3][1], 'not-a-hash', 'non-hash args untouched');
is($calls->[4][1]{accountId}, 'other_user', 'non-matching accountId not rewritten');

done_testing;
