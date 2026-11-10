#!/usr/bin/perl
# JMAP::CredentialStore: a credential is encrypted under a key derived from
# JMAP_SECRET_KEY (a real 256-bit key, never a passphrase) and bound to its
# account and field; without a key, nothing is stored unless plaintext is
# asked for.
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::CredentialStore;

my $CS = 'JMAP::CredentialStore';
my $ctx  = JMAP::CredentialStore::context('acct1', 'iserver.password');
my $ctx2 = JMAP::CredentialStore::context('acct2', 'iserver.password');
my $ctx3 = JMAP::CredentialStore::context('acct1', 'jserver.password');
my $dies = sub { my $code = shift; return eval { $code->(); 1 } ? '' : "$@" };

{
  local $ENV{JMAP_SECRET_KEY} = '0123456789abcdef' x 4;
  $CS->reset;
  my $enc = $CS->encrypt('hunter2', $ctx);
  like($enc, qr/^enc2:/, 'enc2 format');
  is($CS->decrypt($enc, $ctx), 'hunter2', 'round trip');
  isnt($CS->encrypt('hunter2', $ctx), $enc, 'a fresh nonce each time');
  like($dies->(sub { $CS->decrypt($enc, $ctx2) }), qr/authentication failed/, 'another account\'s credential does not decrypt');
  like($dies->(sub { $CS->decrypt($enc, $ctx3) }), qr/authentication failed/, 'nor another field\'s');
  like($dies->(sub { $CS->decrypt($enc) }), qr/needs a context/, 'decrypt without a context is refused');
  like($dies->(sub { $CS->encrypt('x') }), qr/needs a context/, 'encrypt without a context is refused');
  like($dies->(sub { $CS->decrypt('enc1:AAAA', $ctx) }), qr/old enc1 format/, 'enc1 is no longer read');
  (my $bad = $enc) =~ s/^enc2:(.)/'enc2:' . ($1 eq 'A' ? 'B' : 'A')/e;
  like($dies->(sub { $CS->decrypt($bad, $ctx) }), qr/authentication failed/, 'a tampered value does not decrypt');
  is($CS->decrypt('plain', $ctx), 'plain', 'a plaintext value reads as itself');
  my $mac = $CS->mac('data');
  like($mac, qr/^[0-9a-f]{64}$/, 'mac is a keyed hex digest');
  require Digest::SHA;
  isnt($mac, Digest::SHA::hmac_sha256_hex('data', pack('H*', '0123456789abcdef' x 4)), 'the MAC key is not the master key');

  local $ENV{JMAP_SECRET_KEY} = 'fedcba9876543210' x 4;
  $CS->reset;
  like($dies->(sub { $CS->decrypt($enc, $ctx) }), qr/authentication failed/, 'another master key cannot read it');
}
{
  local $ENV{JMAP_SECRET_KEY} = 'correct horse battery staple';
  $CS->reset;
  like($dies->(sub { $CS->encrypt('x', $ctx) }), qr/64 hex characters/, 'a passphrase is refused');
}
{
  local $ENV{JMAP_SECRET_KEY};
  local $ENV{JMAP_OPENBAO_ADDR};
  local $ENV{JMAP_ALLOW_PLAINTEXT_CREDENTIALS};
  $CS->reset;
  like($dies->(sub { $CS->check_configured }), qr/no encryption configured/, 'no key: refused at startup');
  like($dies->(sub { $CS->encrypt('x', $ctx) }), qr/no encryption configured/, 'and when storing');
  local $ENV{JMAP_ALLOW_PLAINTEXT_CREDENTIALS} = 1;
  $CS->reset;
  ok($CS->check_configured, 'unless plaintext is asked for');
  is($CS->encrypt('x', $ctx), 'x', 'then it is stored as it is');
}
$CS->reset;
like($dies->(sub { JMAP::CredentialStore::context('', 'f') }), qr/needs an account/, 'a context names an account');

done_testing;
