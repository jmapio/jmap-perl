#!/usr/bin/perl
# CORS on the running proxy.  A browser client on another origin (a webmail
# on its own host, e.g. Bulwark) gets its preflight answered and can read
# every answer, redirects and 401s included; another origin cannot; and a
# request without Origin carries no Access-Control-* header.  Before, every
# OPTIONS was 501 (AnyEvent::HTTPD refused the method before any route ran)
# and no answer carried Access-Control-Allow-Origin, so the browser blocked
# the first /session fetch.  The rules themselves are in t/cors-origins.t.
#
#   export JMAP_CORS_ORIGINS=https://webmail.example
#   bin/restart-test-proxy.sh clean
#   JMAP_PROXY_URL=http://localhost:9000 JMAP_MGMT_URL=http://localhost:8081 \
#     prove -lv t/cors.t
#
# The authenticated call logs in as JMAP_TEST_LOGIN (default
# user1@example.com, the account restart-test-proxy.sh registers in IMAP
# mode) with CYRUS_PASS; it is skipped when that login does not work.
use strict;
use warnings;
use Test::More;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);

unless ($ENV{JMAP_PROXY_URL} && $ENV{JMAP_CORS_ORIGINS}) {
  plan skip_all => 'Set JMAP_PROXY_URL, and JMAP_CORS_ORIGINS as the proxy was started with, to enable';
}
my $proxy = $ENV{JMAP_PROXY_URL} =~ s{/\z}{}r;
my ($allowed) = grep { m{\A[a-z][a-z0-9+.-]*://}i } split /[\s,]+/, $ENV{JMAP_CORS_ORIGINS};
plan skip_all => 'JMAP_CORS_ORIGINS names no origin to test with' unless $allowed;
$allowed =~ s{/\z}{};
my $other = 'https://evil.example';

my $http = HTTP::Tiny->new(timeout => 30, max_redirect => 0);

sub preflight {
  my ($path, $origin) = @_;
  return $http->request('OPTIONS', "$proxy$path", { headers => {
    ($origin ? (Origin => $origin) : ()),
    'Access-Control-Request-Method'  => 'POST',
    'Access-Control-Request-Headers' => 'authorization, content-type',
  } });
}

sub vary_has_origin { grep { lc eq 'origin' } split /\s*,\s*/, ($_[0]{headers}{vary} // '') }

# 1. a preflight from the allowed origin, on every path a client calls
for my $path ('/jmap', '/jmap/', '/session', '/upload/someaccount', '/eventsource?types=*',
              '/raw/someaccount/someblob/x.eml', '/.well-known/jmap', '/oauth/token') {
  my $r = preflight($path, $allowed);
  my $h = $r->{headers};
  is($r->{status}, 204, "preflight $path: 204");
  is($h->{'access-control-allow-origin'}, $allowed, "... origin echoed");
  like($h->{'access-control-allow-methods'} // '', qr/\bPOST\b/, '... POST allowed');
  is($h->{'access-control-allow-headers'}, 'authorization, content-type', '... requested headers echoed');
  ok($h->{'access-control-max-age'}, '... a max age');
  ok(!exists $h->{'access-control-allow-credentials'}, '... no Allow-Credentials');
  ok(!length($r->{content} // ''), '... no body');
}

# 2. a preflight from another origin: answered, but nothing allowed
{
  my $r = preflight('/jmap', $other);
  is($r->{status}, 204, 'preflight from another origin: 204');
  ok(!exists $r->{headers}{'access-control-allow-origin'}, '... no Allow-Origin');
  ok(!exists $r->{headers}{'access-control-allow-headers'}, '... no Allow-Headers');
}

# 3. OPTIONS without Origin: no longer 501
{
  my $r = preflight('/jmap', undef);
  isnt($r->{status}, 501, 'OPTIONS without Origin: not 501');
  is($r->{status}, 204, '... 204');
  like($r->{headers}{allow} // '', qr/\bOPTIONS\b/, '... with Allow');
  ok(!exists $r->{headers}{'access-control-allow-origin'}, '... and no Allow-Origin');
}

# 4. the discovery redirect: a cross-origin fetch follows it only if it carries the header
{
  my $r = $http->get("$proxy/.well-known/jmap", { headers => { Origin => $allowed } });
  is($r->{status}, 301, '/.well-known/jmap: 301');
  is($r->{headers}{'access-control-allow-origin'}, $allowed, '... with Allow-Origin');
  ok(vary_has_origin($r), '... and Vary: Origin');
}

# 5. a 401 must reach the client as a 401, not as an opaque CORS failure
{
  my $r = $http->post("$proxy/jmap", { headers => { Origin => $allowed, 'Content-Type' => 'application/json' },
                                       content => '{"using":[],"methodCalls":[]}' });
  is($r->{status}, 401, 'unauthenticated POST /jmap: 401');
  is($r->{headers}{'access-control-allow-origin'}, $allowed, '... with Allow-Origin');
  ok(!exists $r->{headers}{'access-control-allow-credentials'}, '... no Allow-Credentials');
}

# a 200 without a login: the OIDC discovery document
{
  my $r = $http->get("$proxy/.well-known/openid-configuration", { headers => { Origin => $allowed } });
  is($r->{status}, 200, '/.well-known/openid-configuration: 200');
  is($r->{headers}{'access-control-allow-origin'}, $allowed, '... with Allow-Origin');
  ok(vary_has_origin($r), '... and Vary: Origin');
  my $o = $http->get("$proxy/.well-known/openid-configuration", { headers => { Origin => $other } });
  ok(!exists $o->{headers}{'access-control-allow-origin'}, '... another origin gets none');
  ok(vary_has_origin($o), '... but Vary: Origin all the same');
}

# 6. an authenticated call, as a webmail makes it
SKIP: {
  my $login = $ENV{JMAP_TEST_LOGIN} || 'user1@example.com';
  my $auth  = 'Basic ' . encode_base64("$login:" . ($ENV{CYRUS_PASS} || 'password'), '');
  my $body  = '{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],"methodCalls":[["Mailbox/get",{"accountId":"x","ids":[]},"0"]]}';
  my %h = (Authorization => $auth, 'Content-Type' => 'application/json');
  my $r = $http->post("$proxy/jmap", { headers => { %h, Origin => $allowed }, content => $body });
  skip "cannot log in as $login (HTTP $r->{status}); set JMAP_TEST_LOGIN", 5 if $r->{status} == 401;
  is($r->{status}, 200, 'authenticated POST /jmap from the allowed origin: 200');
  is($r->{headers}{'access-control-allow-origin'}, $allowed, '... with Allow-Origin');
  ok(vary_has_origin($r), '... and Vary: Origin');
  my $o = $http->post("$proxy/jmap", { headers => { %h, Origin => $other }, content => $body });
  is($o->{status}, 200, 'the same from another origin: answered (the browser refuses it)');
  ok(!exists $o->{headers}{'access-control-allow-origin'}, '... without Allow-Origin');
}

# 7. without Origin (a native app, curl): no Access-Control-* header
for my $path ('/.well-known/jmap', '/.well-known/openid-configuration', '/session') {
  my $r = $http->get("$proxy$path");
  is_deeply([ grep { /^access-control-/ } keys %{ $r->{headers} } ], [], "GET $path without Origin: no Access-Control-*");
  is($r->{headers}{'x-frame-options'}, 'DENY', '... the default headers as before');
}

# the management port never answers CORS
SKIP: {
  skip 'Set JMAP_MGMT_URL to check the management port', 1 unless $ENV{JMAP_MGMT_URL};
  my $mgmt = $ENV{JMAP_MGMT_URL} =~ s{/\z}{}r;
  my $r = $http->get("$mgmt/healthz", { headers => { Origin => $allowed } });
  ok(!exists $r->{headers}{'access-control-allow-origin'}, 'management port: no Allow-Origin');
}

done_testing;
