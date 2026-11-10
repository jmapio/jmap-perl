#!/usr/bin/perl
#
# check_accounts validates the account ids on each method call before anything
# is routed or rewritten.
#
# RFC 8620 §3.6.2: a missing required argument is invalidArguments, and an
# accountId that "does not correspond to a valid account" is accountNotFound.
# The proxy used to fill in the authenticated account for a missing accountId;
# that hid client bugs and, for a delegated passthrough binding, could aim the
# call at the wrong upstream account. Now it is rejected up front, and only
# accounts in the session (the pool) are accepted.

use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my $known = { ACCT => 1, OTHER => 1 };

sub errors_for { JMAP::Dispatch::check_accounts($_[0], $known) }

# A present, known accountId is fine.
my $e = errors_for([['Mailbox/get', { accountId => 'ACCT' }, '0']]);
is_deeply($e, {}, 'known accountId passes');

# Absent accountId is invalidArguments naming the argument.
$e = errors_for([['Mailbox/get', {}, '0']]);
is_deeply($e, { 0 => { type => 'invalidArguments', arguments => ['accountId'] } },
  'absent accountId is invalidArguments');

# A non-string accountId is invalidArguments too.
$e = errors_for([['Mailbox/get', { accountId => ['ACCT'] }, '0']]);
is_deeply($e, { 0 => { type => 'invalidArguments', arguments => ['accountId'] } },
  'non-string accountId is invalidArguments');
$e = errors_for([['Mailbox/get', { accountId => undef }, '0']]);
is_deeply($e, { 0 => { type => 'invalidArguments', arguments => ['accountId'] } },
  'null accountId is invalidArguments');

# Unknown accountId is accountNotFound.
$e = errors_for([['Mailbox/get', { accountId => 'NOPE' }, '0']]);
is_deeply($e, { 0 => { type => 'accountNotFound' } }, 'unknown accountId is accountNotFound');

# Errors are keyed by position; good calls leave no entry.
$e = errors_for([
  ['Mailbox/get', { accountId => 'ACCT' }, 'a'],
  ['Mailbox/get', {},                      'b'],
  ['Mailbox/get', { accountId => 'OTHER' }, 'c'],
  ['Mailbox/get', { accountId => 'NOPE' },  'd'],
]);
is_deeply([sort keys %$e], [1, 3], 'only the bad positions are reported');
is($e->{1}{type}, 'invalidArguments', 'position 1 missing');
is($e->{3}{type}, 'accountNotFound',  'position 3 unknown');

# Copy methods need BOTH sides; every missing one is named.
$e = errors_for([['Email/copy', {}, '0']]);
is_deeply($e, { 0 => { type => 'invalidArguments', arguments => ['fromAccountId', 'accountId'] } },
  'copy with neither side is invalidArguments naming both');
$e = errors_for([['Email/copy', { accountId => 'ACCT' }, '0']]);
is_deeply($e, { 0 => { type => 'invalidArguments', arguments => ['fromAccountId'] } },
  'copy missing fromAccountId names just that');
$e = errors_for([['Email/copy', { fromAccountId => 'ACCT', accountId => 'NOPE' }, '0']]);
is_deeply($e, { 0 => { type => 'accountNotFound' } }, 'copy to an unknown account is accountNotFound');
$e = errors_for([['Email/copy', { fromAccountId => 'NOPE', accountId => 'ACCT' }, '0']]);
is_deeply($e, { 0 => { type => 'fromAccountNotFound' } }, 'copy from an unknown account is fromAccountNotFound (RFC 8620 S5.4)');
$e = errors_for([['Email/copy', { fromAccountId => 'NOPE', accountId => 'NOPE2' }, '0']]);
is_deeply($e, { 0 => { type => 'accountNotFound' } }, 'both unknown: accountNotFound wins');
$e = errors_for([['Email/copy', { fromAccountId => 'ACCT', accountId => 'OTHER' }, '0']]);
is_deeply($e, {}, 'copy between two known accounts passes');

# Core/echo has no accountId at all and must never be rejected for lacking one.
$e = errors_for([['Core/echo', { hi => 1 }, '0']]);
is_deeply($e, {}, 'Core/echo needs no accountId');

# RFC 8620 §7.2: a PushSubscription belongs to the login, not to an account.
for my $method (qw(PushSubscription/get PushSubscription/set PushSubscription/changes)) {
  $e = errors_for([[$method, {}, '0']]);
  is_deeply($e, {}, "$method needs no accountId");
}

# A "#accountId" ResultReference supplies the id later; it cannot be checked here
# and must not be reported as missing.
$e = errors_for([['Mailbox/get', { '#accountId' => { resultOf => 'x' } }, '0']]);
is_deeply($e, {}, 'a pending ResultReference for accountId is not treated as missing');

# Malformed calls must not blow up (the request validator rejects them, but this
# is called on the raw list).
my $ok = eval { errors_for(['notacall', ['Mailbox/get', undef, '1']]); 1 };
ok($ok, 'malformed calls are skipped rather than dying');

# A "#accountId" passes check_accounts unresolved; once resolved it is checked
# again, or a reference could send the call to any account's worker
{
  my %key = (A => 'imap:A', B => 'imap:B', P => 'fp:1', Q => 'fp:1');
  my $p = sub { JMAP::Dispatch::resolved_account_problem([ 'Email/get', $_[0], 't' ], \%key, $_[1]) };
  is($p->({ accountId => 'A' }, 'imap:A'), undef, 'a session account on this batch\'s upstream is fine');
  is($p->({ accountId => 'victim' }, 'imap:A')->{type}, 'accountNotFound', 'one outside the session is accountNotFound');
  is($p->({ accountId => 'B' }, 'imap:A')->{type}, 'invalidArguments', 'one of the session, but another upstream, is refused');
  is($p->({ accountId => 'Q' }, 'fp:1'), undef, 'a delegated account on the same login is fine');
  is($p->({ accountId => { x => 1 } }, 'imap:A')->{type}, 'accountNotFound', 'a resolved non-string is refused');
  is($p->({ accountId => 'A', fromAccountId => 'nope' }, 'imap:A')->{type}, 'fromAccountNotFound', 'fromAccountId too');
}

# A field given both plain and as a "#" reference is invalidArguments at
# once (RFC 8620 S3.7): copy orchestration never resolves references, and it
# took the plain, unchecked, fromAccountId -- any account's
{
  my $e = JMAP::Dispatch::check_accounts([
    [ 'Blob/copy', { accountId => 'A', fromAccountId => 'victim', '#fromAccountId' => {} }, 'c0' ],
    [ 'Email/get', { accountId => 'victim', '#accountId' => { resultOf => 'x', name => 'Core/echo', path => '/a' } }, 'c1' ],
    [ 'Blob/copy', { accountId => 'A', '#fromAccountId' => { resultOf => 'x', name => 'Core/echo', path => '/a' } }, 'c2' ],
  ], { A => 1 });
  is_deeply($e->{0}, { type => 'invalidArguments', arguments => ['fromAccountId'] }, 'copy: fromAccountId and #fromAccountId together');
  is_deeply($e->{1}, { type => 'invalidArguments', arguments => ['accountId'] }, 'accountId and #accountId together');
  ok(!$e->{2}, 'a reference alone is left to resolve');
}

# The d* helpers splice an [operator, value] filter's operator into SQL:
# only comparison operators are taken
{
  require JMAP::DB;
  is(JMAP::DB::_cond('jmodseq', ['>', 3]), 'jmodseq > ?', 'a comparison is taken');
  is(JMAP::DB::_cond('msgid', 'x'), 'msgid = ?', 'a plain value is equality');
  for my $op ('= 1 UNION SELECT password FROM iserver --', 'LIKE', '', undef, ['>']) {
    ok(!eval { JMAP::DB::_cond('msgid', [$op, 'x']); 1 }, 'refused operator: ' . (defined $op ? (ref $op ? 'a reference' : "'$op'") : 'undef'));
  }
}

done_testing;
