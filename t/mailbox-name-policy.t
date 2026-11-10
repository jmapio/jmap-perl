#!/usr/bin/perl
# Mailbox names: at least one character, at most 490 octets, and (policy)
# not beginning with "(": IMAP libraries send such a name unquoted, as a
# list, so it cannot be created or renamed to reliably (RFC 8621 S2.5 lets a
# server refuse names it will not support).
use strict;
use warnings;
use Test::More;
use lib '.';
require JMAP::API;

my $bad = sub { [ JMAP::API::_mailbox_bad_props($_[0], $_[1], {}) ] };
is_deeply($bad->({ name => '(Archive)' }), ['name'], 'create: a name starting with "(" is refused');
is_deeply($bad->({ name => '(' }), ['name'], 'a lone "("');
is_deeply($bad->({ name => '(x' }, 'mb1'), ['name'], 'a rename to one too');
is_deeply($bad->({ name => 'Archive (old)' }), [], 'a "(" further in is fine');
is_deeply($bad->({ name => ' (x' }), [], 'one after a space is not at the start');
is_deeply($bad->({ name => '' }), ['name'], 'empty is still refused, once');
is_deeply($bad->({ sortOrder => 3 }, 'mb1'), [], 'an update without a name is not judged on it');

done_testing;
