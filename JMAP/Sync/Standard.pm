#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Standard;
use base qw(JMAP::Sync::Common);

use Mail::IMAPTalk;
use Email::Sender::Transport::SMTP;
use Sys::Hostname;

sub _imap_class { 'Mail::IMAPTalk' }

sub _imap_ssl {
  my $Self = shift;
  # Internal: 1=plain, 2=SSL; IMAPTalk: 0=plain, 1=SSL. An unset/invalid value
  # must not degrade to plaintext — that just hangs against an implicit-TLS 993.
  (($Self->{auth}{imapSSL} || 2) > 1) ? 1 : 0;
}

sub _imap_extra {
  $ENV{IGNORE_INVALID_CERT}
    ? (SSL_verify_mode => 0, verify_hostname => 0)
    : ();
}

sub _smtp_transport {
  my ($Self, $helo) = @_;
  # Falling back to plaintext here is never right: submission servers only
  # advertise AUTH after the connection is secured, so an unset value would
  # make every send fail with "no AUTH mechanism". Default to STARTTLS.
  my $smtpSSL = $Self->{auth}{smtpSSL} || 3;
  Email::Sender::Transport::SMTP->new({
    helo          => $helo,
    host          => $Self->{auth}{smtpHost},
    port          => $Self->{auth}{smtpPort},
    ($smtpSSL == 2 ? (ssl => 'ssl') : ()),
    ($smtpSSL == 3 ? (ssl => 'starttls') : ()),
    sasl_username => $Self->{auth}{username},
    sasl_password => $Self->{auth}{password},
  });
}

1;
