#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::CalDAVTalk;

# GetCalendars has DAV:acl in its PROPFIND and no way to leave it out. Below the
# calendar home SOGo also lists <calendar>.ics and <calendar>.xml, which can't
# answer it: the exception comes back as a 501 for the whole request, so not a
# single calendar syncs. Nothing here reads the ACLs, so they aren't asked for.

use base qw(Net::CalDAVTalk);

# SOGo answers a sync-collection REPORT on a calendar that has never held an
# event with the sync-token "0". SyncEventLinks tests the token for truth, so
# it dies on "0" and the whole calendar sync fails. The token is swapped for a
# placeholder on the way in and back to "0" on the way out.
use constant ZERO_SYNC_TOKEN => 'jmap-proxy:sync-token-0';

sub Request {
  my ($Self, $Method, $Path, $Content, @Rest) = @_;

  if ($Method eq 'PROPFIND') {
    $Content = "$Content";
    $Content =~ s{<D:acl\s*/>}{};
  }

  my $Response = $Self->SUPER::Request($Method, $Path, $Content, @Rest);

  if ($Method eq 'REPORT' and ref($Response) eq 'HASH') {
    my $NS_D = $Self->ns('D');
    my $Token = $Response->{"{$NS_D}sync-token"};
    $Token->{content} = ZERO_SYNC_TOKEN
      if ref($Token) eq 'HASH' and ($Token->{content} // '') eq '0';
  }

  return $Response;
}

sub SyncEventLinks {
  my ($Self, @Args) = @_;

  my ($Added, $Removed, $Errors, $SyncToken) = $Self->SUPER::SyncEventLinks(@Args);
  $SyncToken = '0' if defined $SyncToken and $SyncToken eq ZERO_SYNC_TOKEN;

  return ($Added, $Removed, $Errors, $SyncToken);
}

1;
