#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::Capabilities;

use JSON;
require JMAP::API::Blob;   # blob_account_capabilities(), no DB needed
require JMAP::FileNode;   # %CAPS

use Exporter 'import';
our @EXPORT_OK = qw(imap_account_capabilities);

# How far ahead an EmailSubmission may be held (HOLDFOR/HOLDUNTIL on its
# mailFrom): the proxy holds the message itself
# (JMAP::ImapDB::create_submissions, send_due).
our $MAX_DELAYED_SEND = 30 * 86400;

# The accountCapabilities for an IMAP-backed account, as it appears both in the
# session resource (RFC 8620 S1.6.2) and in a Principal's "accounts" map
# (RFC 9670 S2). $conf needs only caldavURL, carddavURL and webdavURL (plus
# baseurl for FileNode's webWriteUrlTemplate): the parent passes the account's
# details, the per-account worker passes its iserver row.
# The proxy's own base URL: what the parent passes, else BASEURL as
# bin/jmap-proxy.pl works it out (a worker building a Principal has no
# $conf->{baseurl}, and must advertise the same template as the session).
sub _baseurl {
  my ($conf) = @_;
  my $base = $conf->{baseurl} || $ENV{BASEURL} || 'http://localhost:' . ($ENV{JMAP_PORT} || 9000);
  return $base =~ s{/+\z}{}r;
}

# FileNode needs a WebDAV home that a Probe has worked on: the parent's
# account details carry that as "filenode"; an iserver row (a worker) has
# webdavFeatures, which only a successful Probe stores.
sub filenode_ok {
  my ($conf) = @_;
  return 0 unless $conf && $conf->{webdavURL};
  return $conf->{filenode} ? 1 : 0 if exists $conf->{filenode};
  my $f = $conf->{webdavFeatures} ? eval { decode_json($conf->{webdavFeatures}) } : undef;
  return (ref $f eq 'HASH' && %$f) ? 1 : 0;
}

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
    # draft-ietf-jmap-filenode S2: only for an account with a WebDAV home
    # that a Probe has worked on (a server with no WebDAV advertises nothing).
    (filenode_ok($conf) ? ('urn:ietf:params:jmap:filenode' => {
      %JMAP::FileNode::CAPS,
      webWriteUrlTemplate => _baseurl($conf) . '/filenode/{accountId}/{id}',
    }) : ()),
  };
}

1;
