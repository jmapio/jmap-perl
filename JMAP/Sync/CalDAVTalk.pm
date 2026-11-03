#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::CalDAVTalk;

# GetCalendars has DAV:acl in its PROPFIND and no way to leave it out. Below the
# calendar home SOGo also lists <calendar>.ics and <calendar>.xml, which can't
# answer it: the exception comes back as a 501 for the whole request, so not a
# single calendar syncs. Nothing here reads the ACLs, so they aren't asked for.

use base qw(Net::CalDAVTalk);

# When a sync-collection REPORT comes back without a sync-token, Net::CalDAVTalk
# dies with "NO SYNC TOKEN RETURNED " . Dumper($Response) but never loads
# Data::Dumper, so the log only says "Undefined subroutine
# &Net::CalDAVTalk::Dumper" instead of what the server answered.
use Data::Dumper ();
{
  no warnings 'once';
  *Net::CalDAVTalk::Dumper = \&Data::Dumper::Dumper unless defined &Net::CalDAVTalk::Dumper;
}

sub Request {
  my ($Self, $Method, $Path, $Content, @Rest) = @_;

  if ($Method eq 'PROPFIND') {
    $Content = "$Content";
    $Content =~ s{<D:acl\s*/>}{};
  }

  return $Self->SUPER::Request($Method, $Path, $Content, @Rest);
}

1;
