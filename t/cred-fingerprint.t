#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

my $dir;
BEGIN { require File::Temp; $dir = File::Temp::tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

my $fp1 = JMAP::JmapDB::cred_fingerprint({
  apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
});
my $fp2 = JMAP::JmapDB::cred_fingerprint({
  apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
});
my $fp3 = JMAP::JmapDB::cred_fingerprint({
  apiUrl => 'https://up.example/jmap', username => 'u2', authType => 'basic', secret => 'pw',
});

is($fp1, $fp2, 'same credentials produce the same fingerprint');
isnt($fp1, $fp3, 'different username produces a different fingerprint');
like($fp1, qr/^[0-9a-f]{64}$/, 'fingerprint is a sha256 hex string');

done_testing;
