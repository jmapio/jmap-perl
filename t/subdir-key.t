#!/usr/bin/perl
# t/subdir-key.t -- a payload key (an event or card uid, from a client or a
# synced invite) can never name a file outside the account's directory.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

BEGIN { $ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1) }
use JMAP::DB;

is(JMAP::DB::_subdir_key('abc-123@example.com.json'), 'abc-123@example.com.json', 'a plain uid keeps its name');
for my $bad ('../../other/jevents/x.json', 'a/b.json', '..json', ".hidden", "nul\0.json", '') {
  my $k = JMAP::DB::_subdir_key($bad);
  like($k, qr/\A_h_[0-9a-f]{40}\z/, "'" . ($bad =~ s/\0/\\0/r) . "' is stored under its hash");
}
isnt(JMAP::DB::_subdir_key('a/b'), JMAP::DB::_subdir_key('a/c'), 'different keys, different hashes');

my $db = bless {}, 'JMAP::DB';
no warnings 'redefine';
local *JMAP::DB::accountid = sub { 'acct' };
$db->write_subdir('jevents', '../../escape.json', '{}');
ok(!-e "$ENV{JMAP_DATADIR}/escape.json" && !-e "$ENV{JMAP_DATADIR}/../escape.json",
   'a ../ key writes nothing outside the directory');
is($db->read_subdir('jevents', '../../escape.json'), '{}', 'and reads back through the same key');

done_testing;
