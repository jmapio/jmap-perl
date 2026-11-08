#!/usr/bin/perl
# draft-ietf-jmap-calendars-33 changes: the participant filter, sorting by
# id and by the instant an event starts, after/before as LocalDateTimes in
# the query's timeZone (recurring events included), useDefaultAlerts on
# get, and the S5.9 rules for version and updated on /set.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::XS ();
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

{
  package FakeCalDAV;
  our @calls;
  sub new { bless {}, shift }
  sub connection_lost { 0 }
  sub AUTOLOAD { our $AUTOLOAD; (my $m = $AUTOLOAD) =~ s/.*:://; return if $m eq 'DESTROY';
                 push @calls, [$m, @_[1..$#_]]; return 1 }
  sub can { 1 }
}

my $db = JMAP::ImapDB->new('c33');
$db->{backend} = FakeCalDAV->new;
my $api = JMAP::API->new($db);
no warnings qw(redefine once);
*JMAP::ImapDB::sync_calendars = sub { };

$db->begin();
$db->get_user()->{email} = 'me@example.com';
$db->dupdate('account', { email => 'me@example.com' });
my $cal = $db->dmake('jcalendars', { name => 'C', active => 1 });
$db->dinsert('icalendars', { href => '/cal/C/', jcalendarid => $cal, name => 'C' });
my %ev = (
  # 09:00 in Sydney (UTC+11 in January) is 22:00 the day before in UTC: first by instant
  syd  => { start => '2026-01-10T09:00:00', timeZone => 'Australia/Sydney', duration => 'PT1H', title => 'Sydney',
            participants => { p1 => { name => 'Ann Chair', calendarAddress => 'mailto:ann@example.com', roles => { chair => JSON::XS::true } } } },
  utc  => { start => '2026-01-10T08:00:00', timeZone => 'Etc/UTC', duration => 'PT1H', title => 'UTC' },
  float=> { start => '2026-01-10T12:00:00', duration => 'PT1H', title => 'Floating' },
  rec  => { start => '2026-01-05T10:00:00', timeZone => 'Etc/UTC', duration => 'PT1H', title => 'Weekly',
            recurrenceRule => { '@type' => 'RecurrenceRule', frequency => 'weekly', count => 3 } },
);
for my $uid (sort keys %ev) {
  $db->dinsert('ievents', { icalendarid => 1, uid => $uid, href => "/cal/C/$uid.ics", etag => 'x' });
  $db->set_event([$cal], { uid => $uid, '@type' => 'Event', %{ $ev{$uid} } });
}
$db->commit();

my $query = sub { my ($r) = $api->api_CalendarEvent_query({ accountId => 'c33', @_ }); $r->[0] eq 'error' ? $r : $r->[1]{ids} };

is_deeply($query->(filter => { participant => 'ann chair' }), ['syd'], 'participant (was attendee) matches any role');
is_deeply($query->(filter => { attendee => 'ann@' }), ['syd'], 'attendee is still taken');

is_deeply($query->(sort => [{ property => "start" }]), [qw(rec syd utc float)],
          'start sorts by instant: Sydney 09:00 is 22:00 UTC the day before') ;
is_deeply($query->(sort => [{ property => 'id', isAscending => JSON::XS::false }]), [qw(utc syd rec float)], 'id is a supported sort');

# after/before are local times in the query's timeZone
is_deeply([ sort @{ $query->(filter => { after => '2026-01-10T09:30:00', before => '2026-01-10T13:00:00' }) } ], [qw(float)],
          'UTC query zone: 08:00Z and 22:00Z the day before are out; floating 12:00 is in');
is_deeply([ sort @{ $query->(timeZone => 'Australia/Sydney', filter => { after => '2026-01-10T08:30:00', before => '2026-01-10T09:30:00' }) } ],
          [qw(syd)], 'Sydney query zone: the Sydney 09:00 event is in');

# a recurring event without expansion matches by any occurrence
is_deeply($query->(filter => { after => '2026-01-19T00:00:00', before => '2026-01-20T00:00:00' }), ['rec'],
          'recurring: its third week matches');
is_deeply($query->(filter => { after => '2026-01-27T00:00:00', before => '2026-01-28T00:00:00' }), [],
          'recurring: after its last occurrence nothing does');

# with expandRecurrences, each instance by its own instant
my $exp = $query->(expandRecurrences => JSON::XS::true, filter => { after => '2026-01-11T00:00:00', before => '2026-01-20T00:00:00' });
is(scalar @$exp, 2, 'expanded: two of the three instances in range') or diag explain $exp;

my ($g) = $api->api_CalendarEvent_get({ accountId => 'c33', ids => ['utc'] });
ok(exists $g->[1]{list}[0]{useDefaultAlerts} && !$g->[1]{list}[0]{useDefaultAlerts}, 'useDefaultAlerts is in a get without properties');

# /set: version on create; updated on an event this account originates, not otherwise
@FakeCalDAV::calls = ();
my ($made) = $db->create_calendar_events({ n => { '@type' => 'Event', title => 'New', calendarIds => { $cal => JSON::XS::true } } });
is($made->{n}{version}, '2.0', 'created reports the version the server set');
ok($made->{n}{updated}, 'and updated, on an event with no organizer');
my ($made2) = $db->create_calendar_events({ m => { '@type' => 'Event', title => 'Invite', calendarIds => { $cal => JSON::XS::true },
  organizerCalendarAddress => 'mailto:boss@example.com' } });
ok(!exists $made2->{m}{updated}, 'not on one somebody else organizes');

my ($changed) = $db->update_calendar_events({ utc => { title => 'x', updated => '2000-01-01T00:00:00Z' } });
ok($changed->{utc} && $changed->{utc}{updated} && $changed->{utc}{updated} ne '2000-01-01T00:00:00Z',
   'update of an origin event: the server sets updated, over the client\'s, and reports it');
$db->begin(); $db->set_event([$cal], { uid => 'inv', '@type' => 'Event', organizerCalendarAddress => 'mailto:boss@example.com' });
$db->dinsert('ievents', { icalendarid => 1, uid => 'inv', href => '/cal/C/inv.ics', etag => 'x' }); $db->commit();
@FakeCalDAV::calls = ();
($changed) = $db->update_calendar_events({ inv => { title => 'y' } });
ok(exists $changed->{inv} && !defined $changed->{inv}, 'update of an invitation: updated is not set');
my ($upd) = grep { $_->[0] eq 'update_event' } @FakeCalDAV::calls;
ok(!exists $upd->[2]{updated}, 'and not sent');

done_testing;
