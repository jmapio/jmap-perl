#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::Capabilities;

use JSON;
require JMAP::API::Blob;   # blob_account_capabilities(), no DB needed

use Exporter 'import';
our @EXPORT_OK = qw(imap_account_capabilities);

# How far ahead an EmailSubmission may be held (HOLDFOR/HOLDUNTIL on its
# mailFrom): the proxy holds the message itself
# (JMAP::ImapDB::create_submissions, send_due).
our $MAX_DELAYED_SEND = 30 * 86400;

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
    # RFC 8621 S1.3.2.  maxDelayedSend is what says the proxy holds messages
    # itself (HOLDFOR/HOLDUNTIL on mailFrom); submissionExtensions describes
    # the SMTP server, and no MAIL FROM or RCPT TO parameters reach it, so it
    # is empty.  Cyrus does the same: it lists FUTURERELEASE only when its
    # submission server announces it.
    'urn:ietf:params:jmap:submission' => {
      maxDelayedSend       => $MAX_DELAYED_SEND,
      submissionExtensions => {},
    },
    'urn:ietf:params:jmap:vacationresponse' => {},
    # RFC 9404 and draft-ietf-jmap-blobext: what this build can do with blobs
    JMAP::API::blob_account_capabilities(),
    'urn:ietf:params:jmap:mdn'   => {},
    'urn:ietf:params:jmap:quota' => {},
    ($conf->{caldavURL} ? ('urn:ietf:params:jmap:calendars' => {
      maxCalendarsPerEvent     => 1,
      minDateTime              => '1970-01-01T00:00:00Z',
      maxDateTime              => '2099-12-31T23:59:59Z',
      # a JSCalendar Duration has no year unit (RFC 8984 S1.4.6)
      maxExpandedQueryDuration => 'P730D',
      maxParticipantsPerEvent  => undef,
      mayCreateCalendar        => JSON::true,
    },
    'urn:ietf:params:jmap:principals' => {
      currentUserPrincipalId => 'me',
    },
    'urn:ietf:params:jmap:principals:availability' => {
      maxAvailabilityDuration => 'P366D',
    }) : ()),
    ($conf->{carddavURL} ? ('urn:ietf:params:jmap:contacts' => {
      maxAddressBooksPerCard => 1,
      mayCreateAddressBook   => JSON::true,
    }) : ()),
  };
}

1;
