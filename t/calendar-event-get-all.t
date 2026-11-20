#!/usr/bin/perl
# CalendarEvent/get is a standard /get (draft-ietf-jmap-calendars S5.7), so
# `ids: null` -- or no ids at all -- returns every event (RFC 8620 S5.1),
# under their CalendarEvent ids rather than their UIDs, and is
# requestTooLarge once there are more than maxObjectsInGet of them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;
require JMAP::EventId;
require JMAP::Capabilities;

my $db = JMAP::ImapDB->new('evall');
my $api = JMAP::API->new($db);
no warnings qw(redefine once);
*JMAP::ImapDB::sync_calendars = sub { };

$db->begin();
my $jc = $db->dmake('jcalendars', { name => 'A', active => 1 });
my $ic = $db->dinsert('icalendars', { href => '/cal/A/', jcalendarid => $jc, name => 'A' });
for my $uid ('plain1', 'abc@example.com', 'gone1') {
  $db->dinsert('ievents', { icalendarid => $ic, uid => $uid, href => "/cal/A/$uid.ics", etag => 'e' });
  $db->set_event($db->_event_calendars($uid), { uid => $uid, '@type' => 'Event', title => $uid,
    start => '2026-01-01T10:00:00', duration => 'PT1H' });
}
$db->dupdate('jevents', { active => 0 }, { eventuid => 'gone1' });
$db->commit();

my @want = sort map { JMAP::EventId::master_id($_) } 'plain1', 'abc@example.com';

for my $case ([null => { ids => undef }], [omitted => {}]) {
  my ($name, $extra) = @$case;
  my ($r) = $api->api_CalendarEvent_get({ accountId => 'evall', properties => ['title'], %$extra });
  is($r->[0], 'CalendarEvent/get', "ids $name: not an error");
  is_deeply([sort map { $_->{id} } @{ $r->[1]{list} }], \@want, "ids $name: every active event, by id");
  is_deeply($r->[1]{notFound}, [], "ids $name: nothing notFound");
}

my ($one) = $api->api_CalendarEvent_get({ accountId => 'evall',
  ids => [JMAP::EventId::master_id('abc@example.com')], properties => ['title'] });
is($one->[1]{list}[0]{title}, 'abc@example.com', 'an id from the full list fetches its event');

{
  local $JMAP::Capabilities::MAX_OBJECTS_IN_GET = 1;
  my ($r) = $api->api_CalendarEvent_get({ accountId => 'evall', ids => undef });
  is_deeply($r, ['error', { type => 'requestTooLarge' }], 'more events than maxObjectsInGet is requestTooLarge');
}

my ($bad) = $api->api_CalendarEvent_get({ accountId => 'evall', ids => 'plain1' });
is_deeply($bad, ['error', { type => 'invalidArguments', arguments => ['ids'] }], 'ids that is not a list is still invalid');

done_testing;
