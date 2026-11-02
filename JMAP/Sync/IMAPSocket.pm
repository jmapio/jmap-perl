#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::IMAPSocket;

# Sockets for Mail::IMAPTalk that can't wait forever. With UseBlocking it reads
# without select(), so its own Timeout never applies and a connection that goes
# quiet blocks the worker for good. A timeout on the socket ends the read instead,
# and because it counts from the last data, a slow download isn't cut off.

use Errno qw(ETIMEDOUT);
use IO::Socket::IP;
use IO::Socket::SSL;
use Socket qw(SOL_SOCKET SO_RCVTIMEO SO_SNDTIMEO);

# Returns a connected socket, or undef with the reason in $@.
sub connect_to {
  my ($usessl, $timeout, %opts) = @_;
  my $class = $usessl ? 'JMAP::Sync::IMAPSocket::SSL' : 'JMAP::Sync::IMAPSocket::Plain';
  my $socket = $class->new(%opts, Timeout => $timeout) or return undef;
  $socket->blocking(1);
  my $limit = pack('l!l!', $timeout, 0);
  foreach my $opt (SO_RCVTIMEO, SO_SNDTIMEO) {
    setsockopt($socket, SOL_SOCKET, $opt, $limit) or die "setsockopt: $!\n";
  }
  return $socket;
}

# A receive timeout shows up as EAGAIN, and Mail::IMAPTalk 4.07 answers EAGAIN by
# reading again, forever. As ETIMEDOUT it fails the read like a closed connection.
sub _read_result {
  my $bytes = shift;
  $! = ETIMEDOUT if !defined $bytes and $!{EAGAIN};
  return $bytes;
}

package JMAP::Sync::IMAPSocket::Plain;
use base qw(IO::Socket::IP);

sub sysread {
  my $Self = shift;
  return JMAP::Sync::IMAPSocket::_read_result($Self->SUPER::sysread(@_));
}

package JMAP::Sync::IMAPSocket::SSL;
use base qw(IO::Socket::SSL);

sub sysread {
  my $Self = shift;
  return JMAP::Sync::IMAPSocket::_read_result($Self->SUPER::sysread(@_));
}

1;
