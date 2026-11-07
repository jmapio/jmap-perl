#!/usr/bin/perl
# One CalendarEvent per UID, in every calendar holding a copy of it: the
# copies are its calendarIds.  A copy that goes takes only its calendar
# from calendarIds; the last takes the event.  Destroying the event deletes
# every copy; an update changes every copy, and a change to calendarIds
# adds or deletes copies.
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
                 push @calls, [$m, @_[1..$#_]]; return $m eq 'copy_event' ? "copied" : 1 }
  sub can { 1 }
}

my $db = JMAP::ImapDB->new('evcal');
$db->{backend} = FakeCalDAV->new;
my $api = JMAP::API->new($db);
no warnings qw(redefine once);
*JMAP::ImapDB::sync_calendars = sub { };

# two calendars, the event's UID in both
$db->begin();
my ($ja, $jb) = map { $db->dmake('jcalendars', { name => $_, active => 1 }) } qw(A B);
my $ia = $db->dinsert('icalendars', { href => '/cal/A/', jcalendarid => $ja, name => 'A' });
my $ib = $db->dinsert('icalendars', { href => '/cal/B/', jcalendarid => $jb, name => 'B' });
$db->dinsert('ievents', { icalendarid => $ia, uid => 'u1', href => '/cal/A/u1.ics', etag => 'a' });
$db->dinsert('ievents', { icalendarid => $ib, uid => 'u1', href => '/cal/B/u1.ics', etag => 'b' });
$db->set_event($db->_event_calendars('u1'), { uid => 'u1', '@type' => 'Event', title => 'Both',
  start => '2026-01-01T10:00:00', duration => 'PT1H' });
$db->commit();

my $get = sub { my ($r) = $api->api_CalendarEvent_get({ accountId => 'evcal', ids => ['u1'],
  properties => ['calendarIds'] }); return $r->[1]{list}[0] };
is_deeply([sort keys %{ $get->()->{calendarIds} }], [sort ($ja, $jb)], 'calendarIds holds both calendars');

for my $cal ($ja, $jb) {
  my ($q) = $api->api_CalendarEvent_query({ accountId => 'evcal', filter => { inCalendar => "$cal" } });
  is_deeply($q->[1]{ids}, ['u1'], "inCalendar $cal finds it");
}
my ($q) = $api->api_CalendarEvent_query({ accountId => 'evcal', filter => { inCalendars => ["$jb"] } });
is_deeply($q->[1]{ids}, ['u1'], 'so does inCalendars');

# one copy goes: the event stays, in the other calendar
$db->begin();
my ($state0) = $db->get_user()->{jstateCalendarEvent};
$db->ddelete('ievents', { href => '/cal/A/u1.ics' });
$db->_event_copy_gone('u1');
$db->commit();
my $ev = $get->();
ok($ev, 'the event is still there when one copy goes');
is_deeply([keys %{ $ev->{calendarIds} }], ["$jb"], 'in the calendar that still holds it');
$db->begin();
isnt($db->get_user()->{jstateCalendarEvent}, $state0, 'and that is a change');
$db->commit();

# the calendar of the last copy goes: the event goes with it
$db->begin();
$db->ddelete('ievents', { icalendarid => $ib });
$db->ddelete('icalendars', { icalendarid => $ib });
$db->sync_jcalendars();
$db->commit();
ok(!$get->(), 'with the last copy gone, so is the event');

# back in both, for the writes
$db->begin();
$ib = $db->dinsert('icalendars', { href => '/cal/B/', name => 'B' });
$db->sync_jcalendars();
($jb) = $db->dgetfield('icalendars', { icalendarid => $ib }, 'jcalendarid');
$db->dinsert('ievents', { icalendarid => $_->[0], uid => 'u1', href => $_->[1], etag => 'x' })
  for [$ia, '/cal/A/u1.ics'], [$ib, '/cal/B/u1.ics'];
$db->set_event($db->_event_calendars('u1'), { uid => 'u1', '@type' => 'Event', title => 'Both' });
$db->commit();

@FakeCalDAV::calls = ();
my ($changed, $not) = $db->update_calendar_events({ u1 => { title => 'New' } });
is_deeply([sort map { $_->[1] } grep { $_->[0] eq 'update_event' } @FakeCalDAV::calls],
  ['/cal/A/u1.ics', '/cal/B/u1.ics'], 'an update changes every copy');
my @sched = map { $_->[2]{_no_schedule} ? 1 : 0 } grep { $_->[0] eq 'update_event' } @FakeCalDAV::calls;
is_deeply(\@sched, [0, 1], 'scheduling messages go once');

@FakeCalDAV::calls = ();
($changed, $not) = $db->update_calendar_events({ u1 => { calendarIds => { $jb => JSON::XS::true } } });
ok(exists $changed->{u1}, 'taking a calendar out of calendarIds is an update') or diag explain $not;
is_deeply([map { [@$_[0,1]] } grep { $_->[0] eq 'delete_event' } @FakeCalDAV::calls],
  [['delete_event', '/cal/A/u1.ics']], 'which deletes only that calendar\'s copy');

$db->begin(); $db->ddelete('ievents', { href => '/cal/A/u1.ics' }); $db->commit();
@FakeCalDAV::calls = ();
($changed) = $db->update_calendar_events({ u1 => { calendarIds => { $ja => JSON::XS::true, $jb => JSON::XS::true } } });
is_deeply([map { [@$_[0..2]] } grep { $_->[0] eq 'copy_event' } @FakeCalDAV::calls],
  [['copy_event', '/cal/B/u1.ics', '/cal/A/']], 'adding a calendar copies the event there');

$db->begin(); $db->dinsert('ievents', { icalendarid => $ia, uid => 'u1', href => '/cal/A/u1.ics', etag => 'y' }); $db->commit();
@FakeCalDAV::calls = ();
my ($gone) = $db->destroy_calendar_events(['u1']);
is_deeply($gone, ['u1'], 'destroyed');
is_deeply([sort map { $_->[1] } grep { $_->[0] eq 'delete_event' } @FakeCalDAV::calls],
  ['/cal/A/u1.ics', '/cal/B/u1.ics'], 'destroying the event deletes every copy');

@FakeCalDAV::calls = ();
my ($made, $notmade) = $db->create_calendar_events({ c1 => { '@type' => 'Event', title => 'Two',
  calendarIds => { $ja => JSON::XS::true, $jb => JSON::XS::true } } });
ok($made->{c1}, 'an event can be created in two calendars') or diag explain $notmade;
is_deeply([sort map { $_->[1] } grep { $_->[0] eq 'new_event' } @FakeCalDAV::calls], ['/cal/A/', '/cal/B/'],
  'a copy in each');

# a v14 database: each event in its one calendar
{
  require DBI;
  my $file = "$ENV{JMAP_DATADIR}/old14.sqlite3";
  my $old = JMAP::ImapDB->new('old14');
  my $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 });
  $dbh->do('DROP TABLE jevents');
  $dbh->do('CREATE TABLE jevents (eventuid TEXT PRIMARY KEY, jeventhash TEXT, jcalendarid INTEGER,'
         . ' firststart DATE, lastend DATE, jcreated INTEGER, jmodseq INTEGER, mtime DATE, active BOOLEAN)');
  $dbh->do("INSERT INTO jevents (eventuid, jcalendarid, active) VALUES ('old', 7, 1)");
  $dbh->do('PRAGMA user_version = 14');
  $dbh->disconnect;
  JMAP::ImapDB->new('old14');
  $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 });
  is(($dbh->selectrow_array('PRAGMA user_version'))[0], 15, 'v14 migrates to v15');
  is(($dbh->selectrow_array("SELECT jcalendarids FROM jevents WHERE eventuid = 'old'"))[0], '7',
     'an event keeps its calendar');
}

done_testing;
