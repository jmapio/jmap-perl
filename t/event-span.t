#!/usr/bin/perl
# CalendarEvent/query, /queryChanges and Principal/getAvailability read only
# the events whose stored span (JMAP::EventSpan) may reach their range.  The
# prefilter must never drop an event the exact check would keep: answers with
# spans stored must equal answers with every span unknown (NULL).
use strict;
use warnings;
use Test::More;
use JSON ();
use File::Temp qw(tempdir);
use lib '.';
use JMAP::EventSpan;

my $U = $JMAP::EventSpan::UNBOUNDED;
my $n = \&JMAP::EventSpan::naive;

# --- span() --------------------------------------------------------------
is_deeply([JMAP::EventSpan::span({ start => '2026-03-01T10:00:00', duration => 'PT1H' })],
          [$n->('2026-03-01T10:00:00'), $n->('2026-03-01T11:00:00')], 'a single event');
is_deeply([JMAP::EventSpan::span({ start => '2026-03-01', duration => 'P1D', showWithoutTime => JSON::true })],
          [$n->('2026-03-01'), $n->('2026-03-01') + 90000], 'all day: a generous day');
is((JMAP::EventSpan::span({ start => '2026-03-01T10:00:00', recurrenceRule => { frequency => 'daily' } }))[1],
   $U, 'an endless rule is unbounded');
is((JMAP::EventSpan::span({ start => '2026-03-01T10:00:00', duration => 'PT1H',
     recurrenceRule => { frequency => 'daily', count => 3 } }))[1],
   $n->('2026-03-03T11:00:00'), 'count: the last occurrence');
is((JMAP::EventSpan::span({ start => '2026-03-01T10:00:00', duration => 'PT1H',
     recurrenceRule => { frequency => 'daily', until => '2026-03-10T00:00:00' } }))[1],
   $n->('2026-03-10T01:00:00'), 'until bounds it');
is_deeply([JMAP::EventSpan::span({ start => '2026-03-01T10:00:00', duration => 'PT1H',
     recurrenceRule => { frequency => 'daily', count => 3 },
     recurrenceOverrides => { '2026-03-02T10:00:00' => { start => '2025-12-25T09:00:00', duration => 'PT5H' },
                              '2026-06-01T10:00:00' => {},
                              '2027-01-01T10:00:00' => { excluded => JSON::true } } })],
   [$n->('2025-12-25T09:00:00'), $n->('2026-06-01T11:00:00')], 'overrides widen it; an exclusion does not');
is_deeply([JMAP::EventSpan::span({ title => 'no start' })], [undef, undef], 'no start: unknown');
ok(!JMAP::EventSpan::overlaps($n->('2026-03-01T10:00:00'), $n->('2026-03-01T11:00:00'), '2026-03-05T00:00:00', undef),
   'well after: out');
ok(JMAP::EventSpan::overlaps($n->('2026-03-01T10:00:00'), $n->('2026-03-01T11:00:00'), '2026-03-01T20:00:00', undef),
   'within the margin: kept for the exact check');

# --- the prefilter never changes an answer --------------------------------
$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;
srand(11);
my $db = JMAP::ImapDB->new('span');
my $api = JMAP::API->new($db);

my @tz = (undef, 'Etc/UTC', 'Pacific/Kiritimati', 'Pacific/Pago_Pago', 'Australia/Melbourne', 'America/New_York');
sub dt { my ($d, $h) = @_; sprintf '2026-%02d-%02dT%02d:%02d:00', 1 + int($d / 28), 1 + $d % 28, $h, 15 * int rand 4 }
$db->begin();
for my $i (1 .. 150) {
  my $kind = int rand 5;
  my %e = (uid => "ev$i", '@type' => 'Event', title => "e$i", start => dt(int rand 300, int rand 24),
           duration => ('PT1H', 'PT30M', 'P1D', 'PT10H', 'P2DT3H')[int rand 5]);
  $e{timeZone} = $tz[int rand @tz] // delete $e{timeZone};
  $e{recurrenceRule} = { '@type' => 'RecurrenceRule', frequency => 'daily', count => 1 + int rand 20 } if $kind == 1;
  $e{recurrenceRule} = { '@type' => 'RecurrenceRule', frequency => 'weekly', until => dt(int rand 300, 0) } if $kind == 2;
  $e{recurrenceRule} = { '@type' => 'RecurrenceRule', frequency => 'monthly' } if $kind == 3;
  if ($kind && $kind < 4 && rand() < .5) {
    my $rid = $e{start};
    $e{recurrenceOverrides} = { $rid => { start => dt(int rand 300, int rand 24) },
                                dt(int rand 300, 3) => {} };
  }
  $db->set_event([1], \%e);
}
$db->commit();

sub answers {
  my @out;
  for my $w (1 .. 40) {
    my $d = int rand 300;
    my ($after, $before) = (dt($d, int rand 24), dt($d + 1 + int rand 20, int rand 24));
    my $qtz = $tz[int rand @tz];
    my %q = (accountId => 'span', filter => { after => $after, before => $before }, (defined $qtz ? (timeZone => $qtz) : ()));
    push @out, ($api->api_CalendarEvent_query({ %q }))[0][1]{ids};
    push @out, ($api->api_CalendarEvent_query({ %q, expandRecurrences => JSON::true,
                                                sort => [{ property => 'start' }] }))[0][1]{ids};
    push @out, ($api->api_CalendarEvent_query({ %q, filter => { after => $after } }))[0][1]{ids};
    push @out, ($api->api_CalendarEvent_query({ %q, filter => { before => $before } }))[0][1]{ids};
    push @out, ($api->api_Principal_getAvailability({ accountId => 'span', id => 'me',
                  utcStart => "${after}Z", utcEnd => "${before}Z" }))[0][1]{list};
  }
  return \@out;
}

srand(99); my $with = answers();
$db->begin(); $db->dbh->do('UPDATE jevents SET firststart = NULL, lastend = NULL'); $db->commit();
srand(99); my $without = answers();
is(scalar(@$with), 200, 'asked 200 questions');
ok((grep { @$_ } @$with) > 100, 'most answers list something');
for my $i (0 .. $#$with) {
  is_deeply($with->[$i], $without->[$i], "answer $i is the same with spans") or last;
}

# v17 fills in the spans of the events an older version stored (NULL above)
$db->begin(); $db->dbh->do('PRAGMA user_version = 16'); $db->commit();
my $again = JMAP::ImapDB->new('span');
$again->begin();
my ($v) = $again->dbh->selectrow_array('PRAGMA user_version');
my ($unknown) = $again->dbh->selectrow_array('SELECT COUNT(*) FROM jevents WHERE active = 1 AND firststart IS NULL');
$again->commit();
is($v, 18, 'migrated to the current version');
is($unknown, 0, 'every event has its span');

done_testing;
