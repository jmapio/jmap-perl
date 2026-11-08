#!/usr/bin/perl
# RFC 8620 S5.5: every /query honours FilterOperators (AND, OR, NOT) -- it
# goes through one evaluator, JMAP::API::_filter_matches.  CalendarEvent's
# matcher had no operator support at all: any operator matched everything.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $db = JMAP::ImapDB->new('ops');
my $api = JMAP::API->new($db);
no warnings qw(redefine once);
*JMAP::ImapDB::sync_calendars = *JMAP::ImapDB::sync_addressbooks = sub { };

$db->begin();
$db->set_event([1], { uid => 'e1', '@type' => 'Event', title => 'one' });
$db->set_event([2], { uid => 'e2', '@type' => 'Event', title => 'two' });
$db->set_card([1], { uid => 'k1', '@type' => 'Card', name => { full => 'Ann' } });
$db->set_card([2], { uid => 'k2', '@type' => 'Card', name => { full => 'Bob' } });
$db->commit();

my $q = sub { my ($m, $f) = @_; my $meth = "api_${m}_query"; my ($r) = $api->$meth({ accountId => 'ops', filter => $f }); [ sort @{ $r->[1]{ids} || [] } ] };
for my $c ([CalendarEvent => 'inCalendar', 'e'], [ContactCard => 'inAddressBook', 'k']) {
  my ($type, $in, $p) = @$c;
  is_deeply($q->($type, { operator => 'NOT', conditions => [{ $in => '1' }] }), ["${p}2"], "$type: NOT");
  is_deeply($q->($type, { operator => 'OR', conditions => [{ $in => '1' }, { $in => '2' }] }), ["${p}1", "${p}2"], "$type: OR");
  is_deeply($q->($type, { operator => 'AND', conditions => [{ $in => '1' }, { $in => '2' }] }), [], "$type: AND");
  is_deeply($q->($type, { operator => 'AND', conditions => [{ operator => 'NOT', conditions => [{ $in => '2' }] }] }),
            ["${p}1"], "$type: nested");
}

done_testing;
