#!/usr/bin/perl
# RFC 8620 S5.2: more changes than maxChanges is answered with at most
# maxChanges of them, an intermediate newState and hasMoreChanges, not
# cannotCalculateChanges -- and only changes count, not every row.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $db = JMAP::ImapDB->new('paging');
my $api = JMAP::API->new($db);
no warnings qw(redefine once);
*JMAP::ImapDB::sync_calendars = *JMAP::ImapDB::sync_addressbooks = sub { };

my %make = (
  Calendar      => sub { $db->dmake('jcalendars', { name => "c$_[0]", active => 1 }) },
  AddressBook   => sub { $db->dmake('jaddressbooks', { name => "a$_[0]", active => 1 }) },
  CalendarEvent => sub { $db->set_event([1], { uid => "e$_[0]", '@type' => 'Event' }) },
  ContactCard   => sub { $db->dmake('jcontacts', { contactuid => "k$_[0]", jaddressbookid => 1, active => 1 }) },
);
for my $type (sort keys %make) {
  # one change first: a fresh account's first state is not one to page from
  $db->begin(); $make{$type}->(0); $db->commit();
  my $col = { AddressBook => 'jhighestmodseq', ContactCard => 'jstateContact' }->{$type} // "jstate$type";
  $db->begin(); my $start = $db->get_user()->{$col}; $db->commit();
  for my $i (1 .. 5) { $db->begin(); $make{$type}->($i); $db->commit() }
  my $meth = "api_${type}_changes";
  my ($state, @seen, $rounds) = ($start);
  while (1) {
    my ($r) = $api->$meth({ accountId => 'paging', sinceState => "$state", maxChanges => 2 });
    is($r->[0], "$type/changes", "$type/changes answers (round " . ($rounds + 1) . ")") or do { diag explain $r; last };
    my $n = @{ $r->[1]{created} } + @{ $r->[1]{updated} } + @{ $r->[1]{destroyed} };
    cmp_ok($n, '<=', 2, "$type: at most maxChanges");
    push @seen, @{ $r->[1]{created} };
    $state = $r->[1]{newState};
    last unless $r->[1]{hasMoreChanges};
    last if ++$rounds > 5;
  }
  is(scalar @seen, 5, "$type: every change arrives, across the pages");
}

done_testing;
