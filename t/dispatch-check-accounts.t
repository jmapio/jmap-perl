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
is_deeply($e, { 0 => { type => 'accountNotFound' } }, 'copy from an unknown account is accountNotFound');
$e = errors_for([['Email/copy', { fromAccountId => 'ACCT', accountId => 'OTHER' }, '0']]);
is_deeply($e, {}, 'copy between two known accounts passes');

# Core/echo has no accountId at all and must never be rejected for lacking one.
$e = errors_for([['Core/echo', { hi => 1 }, '0']]);
is_deeply($e, {}, 'Core/echo needs no accountId');

# A "#accountId" ResultReference supplies the id later; it cannot be checked here
# and must not be reported as missing.
$e = errors_for([['Mailbox/get', { '#accountId' => { resultOf => 'x' } }, '0']]);
is_deeply($e, {}, 'a pending ResultReference for accountId is not treated as missing');

# Malformed calls must not blow up (the request validator rejects them, but this
# is called on the raw list).
my $ok = eval { errors_for(['notacall', ['Mailbox/get', undef, '1']]); 1 };
ok($ok, 'malformed calls are skipped rather than dying');

done_testing;
