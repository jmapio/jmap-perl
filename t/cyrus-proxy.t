#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use JSON::XS;
use File::Temp qw(tempdir);

unless ($ENV{CYRUS_URL}) {
  plan skip_all => "Set CYRUS_URL, CYRUS_USER, CYRUS_PASS to enable"
    . " (e.g. CYRUS_URL=http://localhost:8080 CYRUS_USER=user1 CYRUS_PASS=password)"
    . " and CYRUS_IMAP_HOST/CYRUS_IMAP_PORT for IMAP";
}

my $cyrus_url  = $ENV{CYRUS_URL};
my $user       = $ENV{CYRUS_USER} || 'user1';
my $pass       = $ENV{CYRUS_PASS} || 'password';
my $imap_host  = $ENV{CYRUS_IMAP_HOST} || 'localhost';
my $imap_port  = $ENV{CYRUS_IMAP_PORT} || 8143;

# Set up temp data directory (must be in BEGIN so it's set before use)
my $datadir;
BEGIN {
  $datadir = File::Temp::tempdir(CLEANUP => 1);
  $ENV{JMAP_DATADIR} = $datadir;
}

use lib '.';

# Load the modules we changed
use JMAP::DB;
use JMAP::ImapDB;
use JMAP::API;
use Data::JSEmail;
use Text::JSContact qw(vcard_to_jscontact jscontact_to_vcard);
use Text::JSCalendar;

# ============================================================
# Test 1: Create an ImapDB account pointed at Cyrus
# ============================================================

my $accountid = "test-$user-" . time();
my $db = eval { JMAP::ImapDB->new($accountid) };
ok($db, "Created ImapDB for $accountid") or BAIL_OUT("Cannot create DB: $@");

# Configure it to point at Cyrus
eval {
  $db->setuser({
    username   => $user,
    password   => $pass,
    imapHost   => $imap_host,
    imapPort   => $imap_port,
    imapSSL    => 0,
    smtpHost   => $imap_host,
    smtpPort   => 25,
    smtpSSL    => 0,
    caldavURL  => $cyrus_url,
    carddavURL => $cyrus_url,
  });
};
ok(!$@, "setuser configured") or diag $@;

# ============================================================
# Test 2: Data::JSEmail parsing works in the DB context
# ============================================================

my $rfc822 = <<"RFC822";
From: Test <$user\@localhost>
To: Test <$user\@localhost>
Subject: JMAP Proxy Test
Date: Sat, 05 Apr 2025 12:00:00 +0000
Message-ID: <proxy-test-\@example.com>
Content-Type: text/plain

Hello from the JMAP proxy test
RFC822

my $parsed = Data::JSEmail::parse($rfc822, 'test-msg-001');
ok($parsed, "Data::JSEmail::parse works in proxy context");
is($parsed->{subject}, 'JMAP Proxy Test', 'subject correct');
is($parsed->{id}, 'test-msg-001', 'id set correctly');
ok($parsed->{bodyValues}, 'bodyValues present');
ok($parsed->{textBody}, 'textBody present');

# Test isodate (used by DB.pm)
my $now = Data::JSEmail::isodate();
like($now, qr/^\d{4}-\d{2}-\d{2}T/, 'isodate works');

# ============================================================
# Test 3: Text::JSContact works for contact creation
# ============================================================

# Test the _contact_to_jscontact helper (used by create_contacts)
my $contact_data = {
  firstName => 'Test',
  lastName  => 'User',
  prefix    => 'Dr.',
  company   => 'TestCorp',
  department => 'Engineering',
  nickname  => 'testy',
  birthday  => '1990-01-15',
  notes     => 'A test contact',
  emails    => [{ value => 'test@example.com' }],
  phones    => [{ value => '+1-555-0123' }],
};

my $card = JMAP::ImapDB::_contact_to_jscontact('test-uid-001', $contact_data);
ok($card, 'contact_to_jscontact works');
is($card->{uid}, 'urn:uuid:test-uid-001', 'uid set');
is($card->{name}{full}, 'Dr. Test User', 'full name built');
ok($card->{emails}, 'emails present');
ok($card->{phones}, 'phones present');
ok($card->{nicknames}, 'nicknames present');
ok($card->{anniversaries}, 'birthday present');
ok($card->{notes}, 'notes present');
ok($card->{organizations}, 'organizations present');

# Verify it produces valid vCard
my $vcard = jscontact_to_vcard($card);
ok($vcard, 'JSContact card converts to vCard');
like($vcard, qr/FN:Dr\. Test User/, 'vCard has correct FN');
like($vcard, qr/test\@example\.com/, 'vCard has email');

# And round-trips
my $reparsed = vcard_to_jscontact($vcard);
ok($reparsed, 'vCard round-trips back to JSContact');
is($reparsed->{name}{full}, 'Dr. Test User', 'name survives round-trip');

# ============================================================
# Test 4: Text::JSCalendar works in CalDAV context
# ============================================================

my $jscal = Text::JSCalendar->new();
my $ical = <<'ICAL';
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
BEGIN:VEVENT
UID:proxy-test-event-001
DTSTART;TZID=America/New_York:20250601T100000
DTEND;TZID=America/New_York:20250601T110000
SUMMARY:Proxy Test Event
LOCATION:Test Room
GEO:40.7128;-74.0060
CATEGORIES:test,proxy
DTSTAMP:20250101T000000Z
END:VEVENT
END:VCALENDAR
ICAL

my @events = $jscal->vcalendarToEvents($ical);
ok(@events, 'vcalendarToEvents works');
is($events[0]{title}, 'Proxy Test Event', 'event title');
ok($events[0]{locations}, 'locations present');
ok($events[0]{keywords}, 'keywords present');

# Test via Net::CalDAVTalk delegation
use Net::CalDAVTalk;
my @events2 = Net::CalDAVTalk->new(url => 'http://localhost/')->vcalendarToEvents($ical);
ok(Net::CalDAVTalk->CompareEvents($events[0], $events2[0]), 'CalDAVTalk delegation matches');

# ============================================================
# Test 5: JMAP API object creation
# ============================================================

my $api = eval { JMAP::API->new($db) };
ok($api, "JMAP::API created") or diag $@;

# Cleanup
eval { $db->delete() };

done_testing();
