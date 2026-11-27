#!/usr/bin/perl
# JMAP::CORS: which origins may read the JMAP port's answers, and the
# Access-Control-* headers that say so.  Pure, no server; t/cors.t checks
# the running proxy.
use strict;
use warnings;
use Test::More;
use lib '.';

use JMAP::CORS;

my $OIDC = {
  'bulwark-webmail' => {
    'https://webmail.example.com/de/auth/callback' => 1,
    'https://webmail.example.com/en/auth/callback' => 1,
    'bulwarkmobile://auth/callback'                => 1,
  },
};

# --- which origins ------------------------------------------------------

for my $unset (undef, '', '  ') {
  my $c = JMAP::CORS->new(origins => $unset, oidc_clients => $OIDC);
  is_deeply([ $c->origins ], [ 'https://webmail.example.com' ],
            'unset or empty JMAP_CORS_ORIGINS: the http(s) redirect URIs\' origins, native app skipped ('
            . (defined $unset ? "'$unset'" : 'undef') . ')');
  is($c->source, 'JMAP_OIDC_CLIENTS', '... and says where they came from');
  ok($c->enabled, '... CORS is on');
}

# the JSON form of JMAP_OIDC_CLIENTS (arrays) works too, and a default port
# or upper case in a redirect URI gives the browser's spelling
is_deeply([ JMAP::CORS->new(oidc_clients => {
              a => [ 'https://WebMail.Example.com:443/cb', 'http://localhost:3000/cb' ],
              b => [ 'https://other.example/x?y=1' ] })->origins ],
          [ 'http://localhost:3000', 'https://other.example', 'https://webmail.example.com' ],
          'redirect URI arrays; default port dropped, host lower-cased');

{
  my $c = JMAP::CORS->new(origins => undef, oidc_clients => {});
  is_deeply([ $c->origins ], [], 'no variables: no origins');
  ok(!$c->enabled, '... CORS is off');
  is($c->source, undef, '... and has no source');
  like($c->describe, qr/\Anone\b/, '... the log says so');
}

{
  my $c = JMAP::CORS->new(
    origins      => 'https://a.example, https://b.example:8443  http://c.example,https://d.example/',
    oidc_clients => $OIDC);
  is_deeply([ $c->origins ],
            [ 'http://c.example', 'https://a.example', 'https://b.example:8443', 'https://d.example' ],
            'a comma- and space-separated list; a lone trailing slash is the same origin');
  is($c->source, 'JMAP_CORS_ORIGINS', '... an explicit list replaces the derived one');
  is($c->allow_origin('https://webmail.example.com'), undef, '... so the OIDC origin is not in it');
  is($c->describe, 'http://c.example https://a.example https://b.example:8443 https://d.example (from JMAP_CORS_ORIGINS)',
     'describe for the startup log');
  is_deeply([ $c->warnings ], [], 'no warnings for a clean list');
}

{
  my $c = JMAP::CORS->new(
    origins => 'https://ok.example https://webmail.example.com/de/auth/callback webmail.example.com '
             . 'null https://user@host.example https://x.example:99999 https://y.example?q');
  is_deeply([ $c->origins ], [ 'https://ok.example' ], 'entries that are not origins are dropped');
  my @w = $c->warnings;
  is(scalar @w, 6, '... each with a warning');
  like($w[0], qr{'https://webmail\.example\.com/de/auth/callback' is not an origin}, '... naming the entry (a path)');
  like($w[1], qr{'webmail\.example\.com' is not an origin}, '... (no scheme)');
  like($w[2], qr{'null' is not an origin}, '... (null is never allowed)');
}

{
  my $c = JMAP::CORS->new(origins => 'tauri://localhost HTTPS://Mail.Example:443');
  is_deeply([ $c->origins ], [ 'https://mail.example', 'tauri://localhost' ],
            'an explicit list may name any scheme (an app\'s webview); spelling normalised');
}

# --- matching -----------------------------------------------------------

{
  my $c = JMAP::CORS->new(origins => 'https://webmail.example.com');
  is($c->allow_origin('https://webmail.example.com'), 'https://webmail.example.com', 'exact origin: echoed');
  for my $bad ('https://webmail.example.com.evil.test', 'http://webmail.example.com',
               'https://webmail.example.com:8443', 'https://evil.webmail.example.com',
               'https://webmail.example.co', 'https://webmail.example.com, https://webmail.example.com',
               'null', '', undef) {
    is($c->allow_origin($bad), undef, 'no match: ' . (defined $bad ? "'$bad'" : 'undef'));
  }
}

{
  my $c = JMAP::CORS->new(origins => '*', oidc_clients => $OIDC);
  ok($c->any && $c->enabled, '"*": any origin');
  is($c->allow_origin('https://anything.example'), '*', '... answered with "*" itself');
  is($c->allow_origin(undef), undef, '... but only for a request that has an Origin');
  is_deeply([ $c->origins ], [ '*' ], '... and the OIDC origins are not added');
}

# --- preflight ----------------------------------------------------------

{
  my $c = JMAP::CORS->new(origins => 'https://webmail.example.com');
  my $h = $c->preflight('https://webmail.example.com', 'authorization, content-type');
  is($h->{'Access-Control-Allow-Origin'}, 'https://webmail.example.com', 'preflight: origin echoed');
  is($h->{'Access-Control-Allow-Methods'}, 'GET, HEAD, POST, PUT, PATCH', '... the methods');
  is($h->{'Access-Control-Allow-Headers'}, 'authorization, content-type', '... the requested headers echoed');
  is($h->{'Access-Control-Max-Age'}, 7200, '... a max age');
  is($h->{Vary}, 'Origin, Access-Control-Request-Headers', '... Vary');
  ok(!exists $h->{'Access-Control-Allow-Credentials'}, '... never Allow-Credentials');
  is($h->{Allow}, 'GET, HEAD, POST, PUT, PATCH, OPTIONS', '... and Allow');

  is($c->preflight('https://webmail.example.com', 'authorization,content-type')->{'Access-Control-Allow-Headers'},
     'authorization,content-type', 'the browser\'s own spelling (no spaces) echoed as is');
  ok(!exists $c->preflight('https://webmail.example.com', undef)->{'Access-Control-Allow-Headers'},
     'no Access-Control-Request-Headers: no Allow-Headers');
  ok(!exists $c->preflight('https://webmail.example.com', "x-a\x00b, \"quoted\"")->{'Access-Control-Allow-Headers'},
     'something that is not a header-name list is not echoed');

  for my $other ('https://evil.example', undef) {
    my $o = $c->preflight($other, 'authorization');
    is_deeply($o, { Allow => 'GET, HEAD, POST, PUT, PATCH, OPTIONS' },
              'preflight from ' . ($other // 'no origin') . ': only Allow');
  }

  my $off = JMAP::CORS->new;
  is_deeply($off->preflight('https://webmail.example.com', 'authorization'),
            { Allow => 'GET, HEAD, POST, PUT, PATCH, OPTIONS' }, 'CORS off: only Allow');
}

# --- actual responses ---------------------------------------------------

{
  my $c = JMAP::CORS->new(origins => 'https://webmail.example.com');

  my %h = ('Content-Type' => 'application/json');
  $c->decorate(\%h, 'https://webmail.example.com');
  is($h{'Access-Control-Allow-Origin'}, 'https://webmail.example.com', 'response: origin echoed');
  is($h{Vary}, 'Origin', '... Vary: Origin');
  ok(!exists $h{'Access-Control-Allow-Credentials'}, '... never Allow-Credentials');

  %h = ('Content-Type' => 'application/json');
  $c->decorate(\%h, 'https://evil.example');
  ok(!exists $h{'Access-Control-Allow-Origin'}, 'another origin: no Allow-Origin');
  is($h{Vary}, 'Origin', '... but Vary: Origin all the same');

  %h = ();
  $c->decorate(\%h, undef);
  is_deeply(\%h, { Vary => 'Origin' }, 'no Origin: only Vary');

  %h = ('access-control-allow-origin' => 'https://set.example', 'vary' => 'Accept-Encoding');
  $c->decorate(\%h, 'https://webmail.example.com');
  is($h{'access-control-allow-origin'}, 'https://set.example', 'a handler\'s own Allow-Origin is kept');
  ok(!exists $h{'Access-Control-Allow-Origin'}, '... and not doubled in another case');
  is($h{vary}, 'Accept-Encoding, Origin', '... its Vary is extended, in its own case');

  %h = (Vary => 'Origin, Access-Control-Request-Headers');
  $c->decorate(\%h, 'https://webmail.example.com');
  is($h{Vary}, 'Origin, Access-Control-Request-Headers', 'Vary already naming Origin is left alone');

  my $off = JMAP::CORS->new;
  %h = ('Content-Type' => 'text/plain');
  $off->decorate(\%h, 'https://webmail.example.com');
  is_deeply(\%h, { 'Content-Type' => 'text/plain' }, 'CORS off: headers unchanged');
}

is(JMAP::CORS::add_vary(undef, 'Origin'), 'Origin', 'add_vary: from nothing');
is(JMAP::CORS::add_vary('*', 'Origin'), '*', 'add_vary: "*" already covers it');
is(JMAP::CORS::add_vary('origin', 'Origin'), 'origin', 'add_vary: case-insensitive');
is(JMAP::CORS::add_vary(' Accept ,Cookie ', 'Origin'), 'Accept, Cookie, Origin', 'add_vary: a messy list tidied');

is(JMAP::CORS::canonical_origin('https://[::1]:8443'), 'https://[::1]:8443', 'canonical_origin: IPv6 literal');
is(JMAP::CORS::canonical_origin('http://localhost:80'), 'http://localhost', 'canonical_origin: http default port');
is(JMAP::CORS::canonical_origin('https://host:0443'), 'https://host', 'canonical_origin: leading zeros in a port');
is(JMAP::CORS::canonical_origin('https://host:0'), undef, 'canonical_origin: port 0');
is(JMAP::CORS::canonical_origin('https://a..b'), undef, 'canonical_origin: empty label');

done_testing;
