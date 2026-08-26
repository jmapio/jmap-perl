#!/usr/bin/perl
use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my %key = (A => 'fp:1', B => 'fp:1', C => 'fp:2');
# Use the REAL classifier, not a stand-in. A stub that matched a general /copy$
# is what let CalendarEvent/copy and ContactCard/copy fall out of the production
# classifier unnoticed — they were forwarded to a worker and came back
# unknownMethod while this file stayed green.
my $route = JMAP::Dispatch::copy_router(\%key, 'A');

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

# EVERY copy method the parent can orchestrate must be routed. This is the
# regression guard: the classifier and _do_copy_call's dispatch table are two
# lists that have already drifted apart once.
my @expected = qw(Blob/copy Email/copy CalendarEvent/copy ContactCard/copy);
is_deeply([JMAP::Dispatch::copy_methods()], [sort @expected],
          'copy_methods covers exactly the methods _do_copy_call implements');

for my $method (@expected) {
  my $b = JMAP::Dispatch::group_batches(
    [[$method, {fromAccountId=>'A', accountId=>'C'}, '0']], \%key, 'A', $route);
  is($b->[0]{key}, 'orchestrate', "$method cross-upstream is orchestrated");

  my $n = JMAP::Dispatch::group_batches(
    [[$method, {fromAccountId=>'A', accountId=>'B'}, '0']], \%key, 'A', $route);
  is($n->[0]{key}, 'fp:1', "$method same-upstream is native-forwarded");
}

# A method that merely looks like a copy is NOT diverted to orchestration —
# it has no _do_copy_call branch, so it must go to its account's upstream.
my $bogus = JMAP::Dispatch::group_batches(
  [['Widget/copy', {fromAccountId=>'A', accountId=>'C'}, '0']], \%key, 'A', $route);
isnt($bogus->[0]{key}, 'orchestrate', 'an unknown /copy method is not orchestrated');

# Omitting fromAccountId means "the account I am authenticated as", so a copy
# from the default account to a same-upstream account still native-forwards.
my $implicit = JMAP::Dispatch::group_batches(
  [['Email/copy', {accountId=>'B'}, '0']], \%key, 'A', $route);
is($implicit->[0]{key}, 'fp:1',
   'copy with an implicit fromAccountId still resolves to the default account');

done_testing;
