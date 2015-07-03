#!/usr/bin/perl -cw

package Net::GmailCalendars;
use base 'Net::CardDAVTalk';

sub auth_header {
  my $Self = shift;
  return "Bearer $Self->{access_token}";
}

1;
