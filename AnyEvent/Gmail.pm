#!/usr/bin/perl -c

package AnyEvent::Gmail;

use strict;
use Mouse;
use base qw(AnyEvent::IMAP);
use MIME::Base64;

has 'token' => (is => 'rw');

sub mkauth_handler {
  my $id = shift;
  return sub {
    my $handle = shift;
    # if we get an ID response then let the regular handler take
    return 1 if $handle->{rbuf} =~ m/^$id /m;
    if ($handle->{rbuf} =~ s/^\+ ?(.+?)\r\n//m) {
      my $plus = $1;
      my $message = $2;
      my $err = eval { decode_base64($message) } || $message;
      die $message; # XXX - we could fire off an event and then return...
      return 1;
    }
    return 0; # we want more text to be sure...
  }
}

sub login {
  my $self = shift;
  my $User = $self->user;
  my $Token = $self->token;
  my $cmd = "user=$User\001auth=Bearer $Token\001\001";
  my $string  = encode_base64($cmd, '');
  my ($id, $cv) = $self->send_cmd("AUTHENTICATE XOAUTH2 $string");
  $self->{socket}->unshift_read(mkauth_handler($id));
  # XXX - error handling
  return $cv;
}

1;
