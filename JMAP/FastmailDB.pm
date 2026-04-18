#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::FastmailDB;
use base qw(JMAP::ImapDB);

# Thin subclass of ImapDB that routes backend_cmd to Sync::Fastmail
# (OAUTHBEARER IMAP/SMTP) instead of Sync::Standard.
# The stored "password" field is an OAuth2 refresh token.

sub backend_cmd {
  my $Self = shift;
  my $cmd  = shift;
  my @args = @_;

  use Carp;
  Carp::confess("in transaction") if $Self->in_transaction();

  unless ($Self->{backend}) {
    require JMAP::Sync::Fastmail;
    require JMAP::CredentialStore;
    my $config = $Self->access_data();
    $config->{password} = JMAP::CredentialStore->decrypt($config->{password} // '');
    $Self->{backend} = JMAP::Sync::Fastmail->new($config)
      || die "failed to setup Fastmail for $config->{username}";
  }

  die "No such command $cmd" unless $Self->{backend}->can($cmd);
  return $Self->{backend}->$cmd(@args);
}

1;
