#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::Capabilities;

use JSON;

use Exporter 'import';
our @EXPORT_OK = qw(imap_account_capabilities);

# The accountCapabilities for an IMAP-backed account, as it appears both in the
# session resource (RFC 8620 S1.6.2) and in a Principal's "accounts" map
# (RFC 9670 S2). $conf needs only caldavURL and carddavURL: the parent passes
# the accounts.sqlite3 row, the per-account worker passes its iserver row.
sub imap_account_capabilities {
  my ($conf) = @_;
  $conf //= {};
  return {
    'urn:ietf:params:jmap:mail' => {
      maxMailboxesPerEmail         => undef,
      maxMailboxDepth              => undef,
      maxSizeMailboxName           => 490,
      maxSizeAttachmentsPerEmail   => 50_000_000,
      emailQuerySortOptions        => [qw(
        receivedAt sentAt size subject from to id
        hasKeyword allInThreadHaveKeyword someInThreadHaveKeyword
      )],
      mayCreateTopLevelMailbox     => JSON::true,
    },
    'urn:ietf:params:jmap:submission' => { maxDelayedSend => 0 },
    'urn:ietf:params:jmap:mdn'   => {},
    'urn:ietf:params:jmap:quota' => {},
    ($conf->{caldavURL} ? ('urn:ietf:params:jmap:calendars' => {
      maxCalendarsPerEvent     => 1,
      minDateTime              => '1970-01-01T00:00:00Z',
      maxDateTime              => '2099-12-31T23:59:59Z',
      maxExpandedQueryDuration => 'P2Y',
      maxParticipantsPerEvent  => undef,
      mayCreateCalendar        => JSON::true,
    },
    'urn:ietf:params:jmap:principals' => {
      currentUserPrincipalId => 'me',
    }) : ()),
    ($conf->{carddavURL} ? ('urn:ietf:params:jmap:contacts' => {
      maxAddressBooksPerCard => 1,
      mayCreateAddressBook   => JSON::true,
    }) : ()),
  };
}

1;
