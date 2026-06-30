#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

my $dir;
BEGIN { $dir = tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

my $db = JMAP::JmapDB->new('acctX');
ok(-f "$dir/acctX.sqlite3", 'creates per-account .sqlite3 file');
ok(!-f "$dir/acctX.db",     'does not create a .db file');

$db->delete;
ok(!-f "$dir/acctX.sqlite3", 'delete removes the .sqlite3 file');

done_testing;
