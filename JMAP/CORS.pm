package JMAP::CORS;

# Which origins a browser may read the JMAP port's answers from, and the
# Access-Control-* headers that say so (Fetch Standard, "CORS protocol").
# A webmail on its own host (Bulwark at webmail.example.com) calls the
# proxy from the browser; without these headers the browser blocks every
# answer, the first /session fetch included.
#
# The origins are JMAP_CORS_ORIGINS, or, where that is unset or empty, the
# origins of the http(s) redirect URIs in JMAP_OIDC_CLIENTS: a webmail
# registered for SSO needs no second setting.
#
# Never Access-Control-Allow-Credentials.  Browser clients send their token
# in Authorization, which a cross-origin fetch carries without credentials
# mode, so the session cookie never rides on a CORS request.
#
# Pure: no I/O.  t/cors-origins.t covers it.

use strict;
use warnings;

# What a preflight allows: what the JMAP port takes (OPTIONS is answered
# before any route, so it is no method a call can use).
our @METHODS = qw(GET HEAD POST PUT PATCH);

# How long a browser may keep a preflight's answer: Chromium's cap.
our $MAX_AGE = 7200;

# A field-name list, as Access-Control-Request-Headers carries it (RFC 9110
# S5.6.2 tokens, comma-separated).  Only such a list is echoed back.
my $TOKEN = qr/[!#\$%&'*+.^_`|~0-9A-Za-z-]+/;
my $TOKEN_LIST = qr/\A[ \t]*$TOKEN(?:[ \t]*,[ \t]*$TOKEN)*[ \t]*\z/;

my %DEFAULT_PORT = (http => 80, https => 443);

# new(origins => $ENV{JMAP_CORS_ORIGINS}, oidc_clients => \%OIDC_CLIENTS)
#
# oidc_clients is { client_id => { redirect_uri => 1 } } (the proxy's
# %OIDC_CLIENTS) or { client_id => [ redirect_uri, ... ] } (the JSON).
sub new {
  my ($class, %args) = @_;
  my $self = bless { any => 0, origins => {}, warnings => [], source => undef }, $class;

  my $list = $args{origins};
  # Empty counts as unset: Compose files pass ${VAR:-}, and an empty value
  # must not quietly turn the derived list off.
  if (defined $list && $list =~ /\S/) {
    $self->{source} = 'JMAP_CORS_ORIGINS';
    for my $entry (grep { length } split /[\s,]+/, $list) {
      if ($entry eq '*') { $self->{any} = 1; next }
      my $origin = canonical_origin($entry);
      if (defined $origin) {
        $self->{origins}{$origin} = 1;
      } else {
        push @{ $self->{warnings} },
          "JMAP_CORS_ORIGINS: '$entry' is not an origin (scheme://host[:port], no path); ignored";
      }
    }
    return $self;
  }

  # Redirect URIs with another scheme (bulwarkmobile://auth/callback)
  # belong to native apps, which need no CORS.
  my $clients = $args{oidc_clients} || {};
  for my $uris (values %$clients) {
    for my $uri (ref $uris eq 'HASH' ? keys %$uris : ref $uris eq 'ARRAY' ? @$uris : ()) {
      next unless defined $uri && !ref $uri;
      my ($base) = $uri =~ m{\A(https?://[^/?#]*)}i or next;
      my $origin = canonical_origin($base);
      $self->{origins}{$origin} = 1 if defined $origin;
    }
  }
  $self->{source} = 'JMAP_OIDC_CLIENTS' if %{ $self->{origins} };
  return $self;
}

# An origin as a browser serialises it in Origin (lower-case scheme and
# host, no default port, no path), or undef for anything that is not one.
# A lone trailing "/" is allowed: "https://host/" is the same origin.
# "null" (a sandboxed frame, a file: page) is never one, since any page can
# send it.
sub canonical_origin {
  my ($s) = @_;
  return undef unless defined $s;
  $s =~ s{/\z}{};
  my ($scheme, $host, $port) = $s =~ m{\A
      ([A-Za-z][A-Za-z0-9+.-]*) ://
      ( [A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)* | \[[0-9A-Fa-f:.]+\] )
      (?: : ([0-9]{1,5}) )?
    \z}x or return undef;
  ($scheme, $host) = (lc $scheme, lc $host);
  if (defined $port) {
    $port += 0;
    return undef if $port < 1 || $port > 65535;
    undef $port if $DEFAULT_PORT{$scheme} && $port == $DEFAULT_PORT{$scheme};
  }
  return "$scheme://$host" . (defined $port ? ":$port" : '');
}

sub enabled  { my ($self) = @_; return $self->{any} || %{ $self->{origins} } ? 1 : 0 }
sub any      { $_[0]{any} }
sub source   { $_[0]{source} }
sub warnings { @{ $_[0]{warnings} } }
sub origins  { my ($self) = @_; return (($self->{any} ? ('*') : ()), sort keys %{ $self->{origins} }) }

# For the startup log: "https://webmail.example.com (from JMAP_OIDC_CLIENTS)".
sub describe {
  my ($self) = @_;
  return 'none (cross-origin browser clients are refused)' unless $self->enabled;
  return join(' ', $self->origins) . " (from $self->{source})";
}

# The Access-Control-Allow-Origin for a request's Origin, or undef.  The
# match is exact, on the browser's own serialisation: nothing is derived
# from the Origin, so a look-alike host, another scheme or another port
# never matches.  With "*", "*" itself.
sub allow_origin {
  my ($self, $origin) = @_;
  return undef unless defined $origin && length $origin;
  return '*' if $self->{any};
  return $self->{origins}{$origin} ? $origin : undef;
}

# The headers of the answer to an OPTIONS request (sent with 204).  For an
# allowed Origin, what a preflight needs; for any other, or none, only
# Allow, and the browser then refuses the call.
#
# Access-Control-Allow-Headers echoes what the browser asked for: safe,
# since only an allowed origin gets it, and it is the only way to cover
# Authorization (a "*" there never does).
sub preflight {
  my ($self, $origin, $request_headers) = @_;
  my %h = (Allow => join(', ', @METHODS, 'OPTIONS'));
  my $allow = $self->allow_origin($origin);
  return \%h unless defined $allow;
  $h{'Access-Control-Allow-Origin'}  = $allow;
  $h{'Access-Control-Allow-Methods'} = join ', ', @METHODS;
  $h{'Access-Control-Allow-Headers'} = $request_headers =~ s/\A[ \t]+|[ \t]+\z//gr
    if defined $request_headers && $request_headers =~ $TOKEN_LIST;
  $h{'Access-Control-Max-Age'}       = $MAX_AGE;
  $h{Vary}                           = 'Origin, Access-Control-Request-Headers';
  return \%h;
}

# Adds to a response's headers (a hashref, changed in place) what CORS
# needs: Access-Control-Allow-Origin for an allowed Origin, unless the
# handler set its own, and, once CORS is on, Vary: Origin on every answer,
# so that no cache hands an answer made for one origin (or for none) to
# another.  With CORS off, nothing.
sub decorate {
  my ($self, $h, $origin) = @_;
  return unless $self->enabled;
  my %key = map { lc $_ => $_ } keys %$h;
  unless ($key{'access-control-allow-origin'}) {
    my $allow = $self->allow_origin($origin);
    $h->{'Access-Control-Allow-Origin'} = $allow if defined $allow;
  }
  my $vary = $key{vary} // 'Vary';
  $h->{$vary} = add_vary($h->{$vary}, 'Origin');
  return;
}

# A Vary value with @names added where it lacks them (case-insensitive).
# "*" already varies on everything.
sub add_vary {
  my ($vary, @names) = @_;
  my @have = grep { length } split /[ \t]*,[ \t]*/, ($vary // '') =~ s/\A[ \t]+|[ \t]+\z//gr;
  return $vary if grep { $_ eq '*' } @have;
  my %seen = map { lc $_ => 1 } @have;
  return join ', ', @have, grep { !$seen{ lc $_ }++ } @names;
}

1;
