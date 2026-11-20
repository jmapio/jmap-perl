#!/usr/bin/perl
# A refused token request says why: the status alone ("400 Bad Request") is
# what Google sends for a refresh token it has expired or revoked, and only
# the body (RFC 6749 S5.2) says that is what happened.
use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json);
use lib '.';
use OAuth2::Tiny;

{
  package FakeUA;
  sub new { my ($class, $res) = @_; bless { res => $res }, $class }
  sub post_form { $_[0]{res} }
}

my $oauth = OAuth2::Tiny->new(client_id => 'c', client_secret => 's', auth_url => 'https://auth.test/a',
                              token_url => 'https://auth.test/token', callback_url => 'https://proxy.test/cb');
my $refuse = sub {
  my ($status, $reason, $content) = @_;
  $oauth->{ua} = FakeUA->new({ success => 0, status => $status, reason => $reason, content => $content });
  eval { $oauth->refresh('rt') };
  return $@;
};

my $err = $refuse->(400, 'Bad Request',
  encode_json({ error => 'invalid_grant', error_description => 'Token has been expired or revoked.' }));
like($err, qr/400 Bad Request \(invalid_grant: Token has been expired or revoked\.\)/, 'the provider\'s reason');
like($err, qr/sign in again/, 'and what to do about an expired or revoked refresh token');

$err = $refuse->(401, 'Unauthorized', encode_json({ error => 'invalid_client' }));
like($err, qr/401 Unauthorized \(invalid_client\)/, 'another reason, without a description');
unlike($err, qr/sign in again/, 'which signing in again would not fix');

$err = $refuse->(502, 'Bad Gateway', '<html>proxy error</html>');
like($err, qr/502 Bad Gateway$|502 Bad Gateway at /, 'a body that is not an OAuth error adds nothing');

$oauth->{ua} = FakeUA->new({ success => 0, status => 400, reason => 'Bad Request',
                             content => encode_json({ error => 'invalid_grant' }) });
eval { $oauth->finish('code') };
like($@, qr/couldn't get refresh token .*\(invalid_grant\)/, 'the code exchange says why too');

done_testing;
