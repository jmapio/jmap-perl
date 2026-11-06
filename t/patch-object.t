#!/usr/bin/perl
# t/patch-object.t -- RFC 8620 S5.3's PatchObject rules, which "MUST be
# rejected with an invalidPatch error" when broken.
use strict;
use warnings;
use Test::More;
use lib '.';
use JSON ();
require JMAP::API;

my $current = {
  keywords => { '$seen' => JSON::true },
  mailboxIds => { m1 => JSON::true },
  alerts => [ { offset => 'PT5M' } ],
  name => 'x',
  empty => undef,
};
my $bad = sub { JMAP::API::_patch_invalid($_[0], $current) };

ok(!$bad->({ 'keywords/$flagged' => JSON::true }), 'a new member of an existing map');
ok(!$bad->({ 'keywords/$seen' => undef }), 'removing a member');
ok(!$bad->({ keywords => {}, name => 'y' }), 'top-level properties only');
ok(!$bad->({ 'keywords/$a' => JSON::true, 'mailboxIds/m2' => JSON::true }), 'two independent pointers');
ok(!$bad->({ 'keywords/a~1b' => JSON::true }), 'an escaped / in the last part');

ok($bad->({ keywords => {}, 'keywords/$seen' => JSON::true }), 'one pointer the prefix of another');
ok($bad->({ 'keywords/$x/y' => JSON::true }), 'a parent that does not exist');
ok($bad->({ 'nosuch/x' => 1 }), 'a top-level parent that does not exist');
ok($bad->({ 'empty/x' => 1 }), 'a parent that is null');
ok($bad->({ 'alerts/0' => {} }), 'a pointer inside an array');
ok($bad->({ 'alerts/0/offset' => 'PT1M' }), 'a pointer further inside an array');
ok($bad->({ 'name/x' => 1 }), 'a parent that is a string');
ok(!JMAP::API::_patch_invalid({ 'keywords' => {}, 'keywordsx' => 1 }, $current),
   'a name that merely starts with another is not its prefix');

done_testing;
