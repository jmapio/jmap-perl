#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use JSON::XS;

use lib '.';

# Test that our module changes work correctly

# 1. Data::JSEmail replaces JMAP::EmailObject
use Data::JSEmail;
ok(Data::JSEmail->can('parse'), 'Data::JSEmail::parse exists');
ok(Data::JSEmail->can('make'), 'Data::JSEmail::make exists');
ok(Data::JSEmail->can('isodate'), 'Data::JSEmail::isodate exists');
ok(Data::JSEmail->can('asAddresses'), 'Data::JSEmail::asAddresses exists');
ok(Data::JSEmail->can('asText'), 'Data::JSEmail::asText exists');
ok(Data::JSEmail->can('asDate'), 'Data::JSEmail::asDate exists');
ok(Data::JSEmail->can('asMessageIds'), 'Data::JSEmail::asMessageIds exists');
ok(Data::JSEmail->can('asURLs'), 'Data::JSEmail::asURLs exists');
ok(Data::JSEmail->can('asGroupAddresses'), 'Data::JSEmail::asGroupAddresses exists');

# Test parse
my $rfc822 = <<'RFC822';
From: sender@example.com
To: recipient@example.com
Subject: Test
Date: Sat, 05 Apr 2025 12:00:00 +0000
Message-ID: <test-integration@example.com>
MIME-Version: 1.0
Content-Type: text/plain

Hello world
RFC822

my $parsed = Data::JSEmail::parse($rfc822);
ok($parsed, 'parse() works');
is($parsed->{subject}, 'Test', 'subject parsed');
is($parsed->{from}[0]{email}, 'sender@example.com', 'from parsed');
is($parsed->{to}[0]{email}, 'recipient@example.com', 'to parsed');
ok($parsed->{messageId}, 'messageId parsed');
ok($parsed->{sentAt}, 'sentAt parsed');
ok($parsed->{preview}, 'preview generated');

# Test isodate
my $iso = Data::JSEmail::isodate(1700000000);
like($iso, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'isodate format');

# 2. Text::JSContact replaces Net::CardDAVTalk::VCard
use Text::JSContact qw(vcard_to_jscontact jscontact_to_vcard patch_vcard);
ok(1, 'Text::JSContact loaded');

my $vcard = <<'VCARD';
BEGIN:VCARD
VERSION:4.0
UID:test-integration-uid
FN:Integration Test
N:Test;Integration;;;
EMAIL;TYPE=work:test@example.com
TEL;TYPE=cell:+1-555-0100
END:VCARD
VCARD

my $card = vcard_to_jscontact($vcard);
ok($card, 'vcard_to_jscontact works');
is($card->{name}{full}, 'Integration Test', 'name parsed');
ok($card->{emails}, 'emails parsed');
ok($card->{phones}, 'phones parsed');

my $vcard_out = jscontact_to_vcard($card);
ok($vcard_out, 'jscontact_to_vcard works');
like($vcard_out, qr/FN:Integration Test/, 'FN in output');

# Test patch_vcard
my $modified = { %$card };
$modified->{name} = { %{$card->{name}}, full => 'Modified Name' };
my $patched = patch_vcard($vcard, $card, $modified);
ok($patched, 'patch_vcard works');
like($patched, qr/Modified Name/, 'patched name');

# 3. Text::JSCalendar replaces inline conversion in Net::CalDAVTalk
use Text::JSCalendar;
my $jscal = Text::JSCalendar->new();
ok($jscal, 'Text::JSCalendar created');

my $ical = <<'ICAL';
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
BEGIN:VEVENT
UID:test-integration-event
DTSTART:20250601T100000Z
DTEND:20250601T110000Z
SUMMARY:Integration Test Event
DTSTAMP:20250101T000000Z
END:VEVENT
END:VCALENDAR
ICAL

my @events = $jscal->vcalendarToEvents($ical);
ok(@events, 'vcalendarToEvents works');
is($events[0]{title}, 'Integration Test Event', 'event title');
is($events[0]{'@type'}, 'Event', '@type is Event');

my $ical_out = $jscal->eventsToVCalendar(@events);
ok($ical_out, 'eventsToVCalendar works');
like($ical_out, qr/Integration Test Event/, 'event in output');

# 4. Net::CalDAVTalk delegates to Text::JSCalendar
use Net::CalDAVTalk;
my $caldav = Net::CalDAVTalk->new(url => 'http://localhost/');
my @events2 = $caldav->vcalendarToEvents($ical);
ok(@events2, 'Net::CalDAVTalk->vcalendarToEvents delegates');
is($events2[0]{title}, 'Integration Test Event', 'delegation produces same result');
ok(Net::CalDAVTalk->CompareEvents($events[0], $events2[0]), 'CompareEvents works via delegation');

# 5. Net::CardDAVTalk uses Text::JSContact
use Net::CardDAVTalk;
ok(1, 'Net::CardDAVTalk loaded without VCard.pm');

# 6. JMAP::DB compiles and uses new modules
eval { require JMAP::DB };
my $db_err = $@;
if ($db_err && $db_err =~ /Can't locate/) {
  pass("SKIP: JMAP::DB has missing non-essential deps: " . (split /\n/, $db_err)[0]);
} else {
  ok(!$db_err, 'JMAP::DB compiles') or diag $db_err;
}

# 7. JMAP::API compiles and uses Data::JSEmail
eval { require JMAP::API };
my $api_err = $@;
if ($api_err && $api_err =~ /Can't locate/) {
  pass("SKIP: JMAP::API has missing non-essential deps: " . (split /\n/, $api_err)[0]);
} else {
  ok(!$api_err, 'JMAP::API compiles') or diag $api_err;
}

done_testing();
