#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Yahoo;
use base qw(JMAP::Sync::Standard);

sub connect_contacts {
  my $Self = shift;

  return unless $Self->{auth}{addressbookurl};

  if ($Self->{contacts}) {
    $Self->{lastused} = time();
    return $Self->{contacts};
  }

  $Self->{contacts} = Net::CardDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => $Self->{auth}{addressbookurl},
    expandurl => 1,
    is_google => 1,
  );

  return $Self->{contacts};
}


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
  return $class->SUPER::new(\%a);
}

1;
