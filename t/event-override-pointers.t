#!/usr/bin/perl
# jscalendarbis-22 S3.3.4: a recurrenceOverrides patch may not touch the
# properties that identify or schedule the event.  "A PatchObject violating
# these restrictions is invalid" -- RFC 8984 had such pointers ignored.
use strict;
use warnings;
use Test::More;
use JSON::XS ();
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;

my $bad = \&JMAP::ImapDB::_event_override_bad;
my $rid = '2024-05-02T09:00:00';
my $check = sub { [ $bad->({ $rid => shift }) ] };

for my $p ('@type', 'method', 'organizerCalendarAddress', 'privacy', 'prodId', 'recurrenceId',
           'recurrenceIdTimeZone', 'sentBy', 'uid', 'participants/p1/calendarAddress',
           'participants/a~1b/calendarAddress', 'recurrenceOverrides', 'recurrenceRule',
           'recurrenceRule/count', 'recurrenceOverrides/2024-05-03T09:00:00/title') {
  is_deeply($check->({ $p => 'x' }), ["recurrenceOverrides/$rid"], "$p is invalid in a patch");
}

for my $p ('title', 'start', 'duration', 'participants', 'participants/p1',
           'participants/p1/name', 'participants/p1/calendarAddress/x', 'locations/l1/name',
           'recurrenceRules', 'uidx', 'privacyx', 'keywords/@type') {
  is_deeply($check->({ $p => 'x' }), [], "$p may be patched");
}

# an exclusion is the one member and nothing else
is_deeply($check->({ excluded => JSON::XS::true }), [], 'an exclusion');
is_deeply($check->({ excluded => JSON::XS::true, title => 'x' }), ["recurrenceOverrides/$rid"],
          'an exclusion with anything else');
is_deeply($check->({ utcStart => '2024-05-02T09:00:00Z' }), ["recurrenceOverrides/$rid"],
          'utcStart (JMAP Calendars S5.9)');
is_deeply($check->({}), [], 'an empty patch: an extra occurrence');

done_testing;
