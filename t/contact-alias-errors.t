#!/usr/bin/perl
# ContactCard/* and AddressBook/* answer under their own names, but an error
# response stays "error" (RFC 8620 S3.6.2): renaming one made the client
# read the error object as a method result.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $db = JMAP::ImapDB->new('alias');
my $api = JMAP::API->new($db);
no warnings 'redefine';
*JMAP::ImapDB::sync_addressbooks = sub { };   # no backend here

for my $m (qw(ContactCard_changes AddressBook_changes)) {
  my ($r) = eval { my $sub = "api_$m"; $api->$sub({ accountId => 'alias', sinceState => 'bogus' }) };
  is($r && $r->[0], 'error', "$m with a bad sinceState answers error") or diag($@);
}
my ($ok) = $api->api_ContactCard_get({ accountId => 'alias', ids => [] });
is($ok->[0], 'ContactCard/get', 'a result is renamed');

done_testing;
