#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::GmailDB;

use base qw(JMAP::ImapDB);

use DBI;
use Date::Parse;
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Encode;
use Encode::MIME::Header;
use Digest::SHA qw(sha1_hex);
use AnyEvent;
use AnyEvent::Socket;
use Data::Dumper;
use JMAP::Sync::Gmail;

sub new {
  my $class = shift;
  my $Self = $class->SUPER::new(@_);
  $Self->{is_gmail} = 1;
  return $Self;
}

sub access_token {
  my $Self = shift;
  require JMAP::CredentialStore;

  $Self->begin();
  my $server = $Self->dgetone('iserver');
  $Self->commit();

  my $refresh_token = JMAP::CredentialStore->decrypt($server->{password});
  my $O    = JMAP::Sync::Gmail::O();
  my $data = $O->refresh($refresh_token);

  return [$server->{imapHost}, $server->{username}, $data->{access_token}, $server->{imapPort}, $server->{imapSSL}];
}

1;
