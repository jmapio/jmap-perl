#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
my $dir;
BEGIN { require File::Temp; $dir = File::Temp::tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }
use lib '.';
use JMAP::JmapDB;

my $calls = [
  ['Email/get',  { accountId => 'pA', ids => ['m1'] }, '0'],
  ['Email/copy', { fromAccountId => 'pA', toAccountId => 'pB', accountId => 'pB' }, '1'],
  ['Email/set',  { accountId => 'pA', create => { k => { x => 'pA stays in body' } } }, '2'],
];

JMAP::JmapDB::_rewrite_method_ids_map($calls, { pA => 'bA', pB => 'bB' });

is($calls->[0][1]{accountId}, 'bA', 'accountId mapped');
is($calls->[1][1]{fromAccountId}, 'bA', 'fromAccountId mapped');
is($calls->[1][1]{toAccountId},   'bB', 'toAccountId mapped');
is($calls->[1][1]{accountId},     'bB', 'copy accountId mapped');
is($calls->[2][1]{create}{k}{x}, 'pA stays in body', 'body untouched');

done_testing;
