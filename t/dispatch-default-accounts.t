#!/usr/bin/perl
#
# apply_default_accounts spells out the account a call leaves implicit.
#
# This matters because the proxy forwards requests to an upstream that applies
# its OWN default — the login's primary account. When a proxy account is bound to
# a delegated upstream account, that is the wrong account, so the id must be made
# explicit before the request is forwarded and the id map applied.

use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

# accountId is filled in when absent.
my $calls = [['Mailbox/get', {}, '0']];
JMAP::Dispatch::apply_default_accounts($calls, 'ACCT');
is($calls->[0][1]{accountId}, 'ACCT', 'absent accountId is defaulted');

# An explicit accountId is never overwritten.
$calls = [['Mailbox/get', { accountId => 'OTHER' }, '0']];
JMAP::Dispatch::apply_default_accounts($calls, 'ACCT');
is($calls->[0][1]{accountId}, 'OTHER', 'explicit accountId is left alone');

# Copy methods get BOTH sides.
$calls = [['Email/copy', {}, '0']];
JMAP::Dispatch::apply_default_accounts($calls, 'ACCT');
is($calls->[0][1]{fromAccountId}, 'ACCT', 'copy fromAccountId is defaulted');
is($calls->[0][1]{accountId},     'ACCT', 'copy accountId is defaulted');

$calls = [['Email/copy', { accountId => 'DEST' }, '0']];
JMAP::Dispatch::apply_default_accounts($calls, 'ACCT');
is($calls->[0][1]{fromAccountId}, 'ACCT', 'copy source defaults to the auth account');
is($calls->[0][1]{accountId},     'DEST', 'copy destination is preserved');

# Core/echo must echo back exactly what it was given — never inject into it.
$calls = [['Core/echo', { hi => 1 }, '0']];
JMAP::Dispatch::apply_default_accounts($calls, 'ACCT');
is_deeply($calls->[0][1], { hi => 1 }, 'Core/echo arguments are untouched');

# A "#accountId" ResultReference must still win, so do not pre-fill the field.
$calls = [['Mailbox/get', { '#accountId' => { resultOf => 'x' } }, '0']];
JMAP::Dispatch::apply_default_accounts($calls, 'ACCT');
ok(!exists $calls->[0][1]{accountId},
   'a pending ResultReference for accountId is not pre-empted');

# Malformed calls must not blow up (the request validator rejects them, but this
# is called on the raw list).
$calls = ['notacall', ['Mailbox/get', undef, '1']];
my $ok = eval { JMAP::Dispatch::apply_default_accounts($calls, 'ACCT'); 1 };
ok($ok, 'malformed calls are skipped rather than dying');

done_testing;
