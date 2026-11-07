#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Workers;

ok(JMAP::Workers::survives_error('__accounts__'), 'the accounts worker survives an error');
ok(!JMAP::Workers::survives_error('u1'), 'an account worker does not');
ok(!JMAP::Workers::survives_error('u1:backfill'), 'nor a backfill worker');

ok(JMAP::Workers::is_background('sync'), 'the periodic sync is background');
ok(!JMAP::Workers::is_background('jmap'), 'a JMAP request is use');
ok(!JMAP::Workers::is_background('send_due'), 'so is a held send');

my $now = 10_000;
my %last = (
  __accounts__  => 0,
  idle          => $now - 400,
  recent        => $now - 100,
  busy          => $now - 400,
  pushed        => $now - 400,
  'filling'     => $now - 400,
  'filling:backfill' => $now - 400,
  'gone:backfill'    => $now - 400,
);
is_deeply([JMAP::Workers::reapable(now => $now, timeout => 300, last_active => \%last,
  busy => { busy => 1 }, keep => { pushed => 1, filling => 1 })],
  ['gone:backfill', 'idle'],
  'reaps idle workers; never the accounts worker, a busy one, or one whose account is kept');
is_deeply([JMAP::Workers::reapable(now => $now, timeout => 300, last_active => { a => $now - 300 },
  busy => {}, keep => {})], [], 'exactly the timeout is not yet idle');

done_testing;
