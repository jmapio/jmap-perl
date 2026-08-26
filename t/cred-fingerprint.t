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

# The fingerprint covers the upstream secret and is stored in plaintext, so with
# a master key configured it must be a KEYED mac — otherwise a stolen database
# would let an attacker guess the password offline.
{
  require JMAP::CredentialStore;
  local $ENV{JMAP_SECRET_KEY} = 'a' x 64;
  JMAP::CredentialStore->reset;
  my $keyed = JMAP::JmapDB::cred_fingerprint({
    apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
  });
  isnt($keyed, $fp1, 'with a master key the fingerprint is keyed, not a bare digest');
  like($keyed, qr/^[0-9a-f]{64}$/, 'keyed fingerprint is still a hex digest');

  my $keyed_again = JMAP::JmapDB::cred_fingerprint({
    apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
  });
  is($keyed_again, $keyed, 'keyed fingerprint is deterministic (comparable across accounts)');

  local $ENV{JMAP_SECRET_KEY} = 'b' x 64;
  JMAP::CredentialStore->reset;
  my $other_key = JMAP::JmapDB::cred_fingerprint({
    apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
  });
  isnt($other_key, $keyed, 'a different master key gives a different fingerprint');
}
JMAP::CredentialStore->reset;

done_testing;
