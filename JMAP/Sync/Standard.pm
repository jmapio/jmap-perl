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
  ($Self->{auth}{imapSSL} || 1) - 1;  # Internal: 1=plain, 2=SSL; IMAPTalk: 0=plain, 1=SSL
}

sub _imap_extra {
  $ENV{IGNORE_INVALID_CERT}
    ? (SSL_verify_mode => 0, verify_hostname => 0)
    : ();
}

sub _smtp_transport {
  my ($Self, $helo) = @_;
  my $smtpSSL = $Self->{auth}{smtpSSL} || 1;
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
