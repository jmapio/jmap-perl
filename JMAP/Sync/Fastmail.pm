#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Fastmail;
use base qw(JMAP::Sync::Standard);

sub new {
  my $class = shift;
  my $auth = shift;
  my %a = (
    imapserver => 'mail.messagingengine.com',
    smtpserver => 'mail.messagingengine.com',
    calurl => 'https://caldav.messagingengine.com/',
    addressbookurl => 'https://carddav.messagingengine.com/',
    %$auth,
  );
  return JMAP::Sync::Standard->new(\%a);
}

1;
