#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::GmailDB;

use base qw(JMAP::ImapDB);

use DBI;
use Date::Parse;
use JSON::XS qw(encode_json decode_json);
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Encode;
use Encode::MIME::Header;
use Digest::SHA qw(sha1_hex);
use AnyEvent;
use AnyEvent::Socket;
use Data::Dumper;
use IO::All;

sub new {
  my $class = shift;
  my $Self = $class->SUPER::new(@_);
  $Self->{is_gmail} = 1;
  return $Self;
}

1;
