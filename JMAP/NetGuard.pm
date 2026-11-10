package JMAP::NetGuard;
use strict;
use warnings;

# Where a user's data may make the proxy connect.  Everything a worker
# connects to -- IMAP, SMTP, CalDAV/CardDAV/WebDAV, an upstream JMAP server
# and the URLs its session names -- comes from what a user typed or what a
# server a user named sent back.  Without a check, a user could point any of
# them at the proxy's own management API on loopback, a cloud metadata
# endpoint, or anything else on the private network, and read the answer
# back through /raw.
#
# The check is on the address actually connected to, after DNS, so a name
# that resolves somewhere else the second time (DNS rebinding) gains
# nothing.  Allowed: public addresses (JMAP::Push::is_public_address), and
# for a self-hosted proxy whose mail server is on its own network:
#   JMAP_ALLOW_PRIVATE_BACKENDS=1     every address
#   JMAP_PRIVATE_ALLOW=10.0.0.5,192.168.1.0/24,fd00::/8   these addresses
# install() puts the check into every socket connect in the process (a
# worker); the parent's AnyEvent::HTTP requests use tcp_connect() below.

use Socket qw(AF_INET AF_INET6 AF_UNIX inet_pton inet_ntop unpack_sockaddr_in unpack_sockaddr_in6 sockaddr_family);
use JMAP::Push ();

my @ALLOW = _parse_allow($ENV{JMAP_PRIVATE_ALLOW} // '');

sub _parse_allow {
  my ($list) = @_;
  my @out;
  for my $item (grep { length } map { s/^\s+|\s+$//gr } split /,/, $list) {
    my ($ip, $bits) = split m{/}, $item, 2;
    my $bin = inet_pton(AF_INET, $ip) // inet_pton(AF_INET6, $ip) // do { warn "JMAP_PRIVATE_ALLOW: not an address: $item\n"; next };
    $bits //= 8 * length $bin;
    push @out, [ $bin, $bits ];
  }
  return @out;
}

# May the proxy connect to $ip (a textual IPv4 or IPv6 address)?
sub allowed {
  my ($ip) = @_;
  return 0 unless defined $ip;
  return 1 if JMAP::Push::is_public_address($ip);
  return 1 if $ENV{JMAP_ALLOW_PRIVATE_BACKENDS};
  my $bin = inet_pton(AF_INET, $ip) // inet_pton(AF_INET6, $ip) // return 0;
  for my $a (@ALLOW) {
    my ($net, $bits) = @$a;
    next unless length $net == length $bin;
    my $full = int($bits / 8);
    next unless substr($net, 0, $full) eq substr($bin, 0, $full);
    my $rest = $bits % 8 or return 1;
    my $mask = (0xff << (8 - $rest)) & 0xff;
    return 1 if (ord(substr($net, $full, 1)) & $mask) == (ord(substr($bin, $full, 1)) & $mask);
  }
  return 0;
}

# The address a packed sockaddr names, or undef for one that is not IP
# (a Unix socket: always allowed).
sub _sockaddr_ip {
  my ($sa) = @_;
  my $fam = eval { sockaddr_family($sa) } // return undef;
  return inet_ntop(AF_INET,  (unpack_sockaddr_in($sa))[1])  if $fam == AF_INET;
  return inet_ntop(AF_INET6, (unpack_sockaddr_in6($sa))[1]) if $fam == AF_INET6;
  return undef;
}

# Check every IO::Socket connect in this process (IO::Socket::IP and
# IO::Socket::INET both connect through it; HTTP::Tiny, Mail::IMAPTalk,
# Net::SMTP and IO::Socket::SSL all use those).  A refused connect fails
# like an unreachable host.
my $installed;
sub install {
  return if $installed++;
  require IO::Socket;
  require IO::Socket::IP;
  no warnings 'redefine';
  # IO::Socket::INET connects through IO::Socket::connect; IO::Socket::IP
  # has its own connect, calling the core one directly.  Both get the check
  # (a connect without an address is IO::Socket::IP polling one in progress).
  for my $class (qw(IO::Socket IO::Socket::IP)) {
    no strict 'refs';
    my $orig = \&{"${class}::connect"};
    *{"${class}::connect"} = sub {
      my ($sock, $addr) = @_;
      if (@_ > 1 and defined(my $ip = _sockaddr_ip($addr))) {
        unless (allowed($ip)) {
          $! = 13;   # EACCES
          warn "NetGuard: refusing to connect to $ip: not a public address (JMAP_PRIVATE_ALLOW / JMAP_ALLOW_PRIVATE_BACKENDS)\n";
          return undef;
        }
      }
      return $orig->(@_);
    };
  }
}

# TLS certificates are checked on every HTTPS request the process makes.
# HTTP::Tiny before 0.083 (Debian bookworm's is 0.082) checks nothing unless
# asked, and nothing here asked: a man in the middle saw the credentials
# sent to DAV and upstream JMAP servers, OAuth tokens and secrets.  Every
# HTTP::Tiny (Net::DAVTalk's and OAuth2::Tiny's included) now defaults to
# verify_SSL; IGNORE_INVALID_CERT, which already turned it off for IMAP,
# turns it off here too (a test server with a self-signed certificate).
# The parent's AnyEvent::HTTP requests pass tls_ctx() below.
sub tls_ctx { return $ENV{IGNORE_INVALID_CERT} ? 'low' : 'high' }
{
  require HTTP::Tiny;
  no warnings 'redefine';
  my $orig = \&HTTP::Tiny::new;
  *HTTP::Tiny::new = sub {
    my ($class, %args) = @_;
    $args{verify_SSL} //= $ENV{IGNORE_INVALID_CERT} ? 0 : 1;
    return $orig->($class, %args);
  };
}

# AnyEvent::HTTP's tcp_connect, refusing any address allowed() refuses.
sub tcp_connect {
  my ($host, $port, $connect_cb, $prepare_cb) = @_;
  require AnyEvent::Socket;
  return AnyEvent::Socket::tcp_connect($host, $port, sub {
    my ($fh, $ip, $peer_port, $retry) = @_;
    return $connect_cb->() unless $fh;
    return $connect_cb->($fh, $ip, $peer_port, $retry) if allowed($ip);
    warn "NetGuard: refusing to connect to $host: $ip is not a public address\n";
    close $fh;
    $retry->();
  }, $prepare_cb);
}

1;
