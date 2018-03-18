#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::AOLDB;

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
  $Self->{is_aol} = 1;
  return $Self;
}

sub access_token {
  my $Self = shift;
  $Self->begin();
  my $server = $Self->dgetone('iserver', {}, 'imapHost,username,password');
  $Self->commit();

  my $O = JMAP::Sync::AOL::O();
  my $data = $O->refresh($server->{password});

  return [$server->{imapHost}, $server->{username}, $data->{access_token}];
}

1;
