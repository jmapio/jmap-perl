#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my %key = (A => 'up1', B => 'up1', C => 'up2');

# consecutive A,B (same key up1) batch together; C breaks to a new batch;
# then A again is a third batch (order preserved, not merged with the first).
my @calls = (
  ['Mailbox/get', { accountId => 'A' }, '0'],
  ['Email/get',   { accountId => 'B' }, '1'],
  ['Email/get',   { accountId => 'C' }, '2'],
  ['Email/get',   { accountId => 'A' }, '3'],
);

my $batches = JMAP::Dispatch::group_batches(\@calls, \%key, 'A');

is(scalar @$batches, 3, 'three batches: [A,B], [C], [A]');
is($batches->[0]{key}, 'up1', 'batch 0 key up1');
is_deeply([map { $_->[0] } @{$batches->[0]{calls}}], [0,1], 'batch 0 positions 0,1');
is($batches->[1]{key}, 'up2', 'batch 1 key up2');
is_deeply([map { $_->[0] } @{$batches->[1]{calls}}], [2], 'batch 1 position 2');
is_deeply([map { $_->[0] } @{$batches->[2]{calls}}], [3], 'batch 2 position 3');

# default account used when accountId absent
my @calls2 = (['Core/echo', {}, 'x']);
my $b2 = JMAP::Dispatch::group_batches(\@calls2, \%key, 'B');
is($b2->[0]{key}, 'up1', 'absent accountId uses default account key');

# unknown account falls back to imap:<aid>
my @calls3 = (['Email/get', { accountId => 'Z' }, 'z']);
my $b3 = JMAP::Dispatch::group_batches(\@calls3, \%key, 'A');
is($b3->[0]{key}, 'imap:Z', 'unknown account falls back to imap:<aid> key');

# copy uses fromAccountId for the account
my @calls4 = (['Email/copy', { fromAccountId => 'C', accountId => 'A' }, 'c']);
my $b4 = JMAP::Dispatch::group_batches(\@calls4, \%key, 'A');
is($b4->[0]{key}, 'up2', 'copy keys off fromAccountId');

done_testing;
