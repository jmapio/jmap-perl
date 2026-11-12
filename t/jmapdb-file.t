#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

my $dir;
BEGIN { $dir = tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

# credentials are encrypted; a fixed key for the test
$ENV{JMAP_SECRET_KEY} //= '00' x 32;

my $db = JMAP::JmapDB->new('acctX');
ok(-f "$dir/acctX.sqlite3", 'creates per-account .sqlite3 file');
ok(!-f "$dir/acctX.db",     'does not create a .db file');

$db->delete;
ok(!-f "$dir/acctX.sqlite3", 'delete removes the .sqlite3 file');

# A signup probe opens no file
my $probe = JMAP::JmapDB->new('probeY', memory => 1);
ok(!-f "$dir/probeY.sqlite3", 'a memory JmapDB leaves no account file');

# One jserver row: a new upstream login replaces the old one. The username is
# the key, so a REPLACE under a new one kept both, and readers took the old.
my $j = JMAP::JmapDB->new('acctZ');
$j->setuser({ username => 'old', password => 'p1', sessionUrl => 'https://a/s', backendAccountId => 'A' });
$j->setuser({ username => 'new', password => 'p2', sessionUrl => 'https://b/s', backendAccountId => 'B' });
my $n = $j->{dbh}->selectrow_array('SELECT COUNT(*) FROM jserver');
is($n, 1, 'one jserver row after a change of login');
is($j->access_data->{username}, 'new', 'the new login is the one read');
is($j->access_data->{backendAccountId}, 'B', 'with its settings');

# A database that already has two rows (from before) reads the newest
$j->{dbh}->do("INSERT INTO jserver (username, password, backendAccountId, mtime) VALUES ('stale', '', 'S', 1)");
is($j->access_data->{username}, 'new', 'an older row is not the one read');

done_testing;
