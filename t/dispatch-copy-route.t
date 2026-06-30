#!/usr/bin/perl
use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my %key = (A => 'fp:1', B => 'fp:1', C => 'fp:2');
# classifier: copy is 'orchestrate' unless from & to share a key
my $route = sub {
  my ($call) = @_;
  return undef unless $call->[0] =~ m{/copy$};
  my $a = $call->[1]{fromAccountId}; my $b = $call->[1]{accountId};
  return (($key{$a}//'') eq ($key{$b}//'')) ? undef : 'orchestrate';
};

# same-upstream copy A->B : normal (batched on fp:1)
my $b1 = JMAP::Dispatch::group_batches(
  [['Email/copy',{fromAccountId=>'A',accountId=>'B'},'0']], \%key, 'A', $route);
is($b1->[0]{key}, 'fp:1', 'same-upstream copy stays on its upstream key');

# cross-upstream copy A->C : orchestrate (standalone)
my $b2 = JMAP::Dispatch::group_batches(
  [['Email/copy',{fromAccountId=>'A',accountId=>'C'},'0']], \%key, 'A', $route);
is($b2->[0]{key}, 'orchestrate', 'cross-upstream copy is orchestrate');

# orchestrate never merges with a neighbouring normal call
my $b3 = JMAP::Dispatch::group_batches([
  ['Email/get',{accountId=>'A'},'0'],
  ['Email/copy',{fromAccountId=>'A',accountId=>'C'},'1'],
  ['Email/get',{accountId=>'A'},'2'],
], \%key, 'A', $route);
is(scalar @$b3, 3, 'orchestrate is isolated into its own batch');
is($b3->[1]{key}, 'orchestrate', 'middle batch is the orchestrate copy');

# two consecutive cross-upstream copies must stay as two separate batches
my $b5 = JMAP::Dispatch::group_batches([
  ['Email/copy',{fromAccountId=>'A',accountId=>'C'},'0'],
  ['Email/copy',{fromAccountId=>'A',accountId=>'C'},'1'],
], \%key, 'A', $route);
is(scalar @$b5, 2, 'two adjacent orchestrate copies are not merged');
is($b5->[0]{key}, 'orchestrate', 'first is orchestrate');
is($b5->[1]{key}, 'orchestrate', 'second is a separate orchestrate batch');

done_testing;
