#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Yahoo;
use base qw(JMAP::Sync::Standard);

sub new {
  my $class = shift;
  my $auth = shift;
  my %a = (
    imapserver => 'imap.mail.yahoo.com',
    smtpserver => 'smtp.mail.yahoo.com',
    calurl => 'https://caldav.calendar.yahoo.com',
    addressbookurl => 'https://carddav.address.yahoo.com',
    %$auth,
  );
  return JMAP::Sync::Standard->new(\%a);
}

1;
