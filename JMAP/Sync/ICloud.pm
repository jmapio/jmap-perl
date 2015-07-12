#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::ICloud;
use base qw(JMAP::Sync::Standard);

sub new {
  my $class = shift;
  my $auth = shift;
  my %a = (
    imapserver => 'imap.mail.me.com',
    smtpserver => 'smtp.mail.me.com',
    calurl => 'https://caldav.icloud.com/',
    addressbookurl => 'https://contacts.icloud.com/',
    %$auth,
  );
  return JMAP::Sync::Standard->new(\%a);
}

1;
