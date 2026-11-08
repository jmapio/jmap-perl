#!/usr/bin/perl
# Every method in the dispatch table, through handle_request, against a
# fresh account with no backend.  Whatever else a method does, it must
# answer (its own name, or an "error" whose type RFC 8620 or its own
# specification defines), leave no transaction open, warn nothing, and keep
# the RFC 8620 shapes: /get of no ids is an empty list with a state, an
# empty /set changes no state, /changes and /queryChanges from the current
# state change nothing.  The safety net for moving method code around.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;
require JMAP::Dispatch;

my $db = JMAP::ImapDB->new('all');
my $api = JMAP::API->new($db);
{
  no warnings qw(redefine once);
  # no server: a method that needs one fails, and says so
  *JMAP::ImapDB::backend_cmd = sub { die "no backend in this test\n" };
  for my $sync (qw(sync_calendars sync_addressbooks sync_folders sync_imap sync_files sync_jmailboxes)) {
    no strict 'refs';
    *{"JMAP::ImapDB::$sync"} = sub { return } if JMAP::ImapDB->can($sync);
  }
}

# RFC 8620 S3.6.2 method errors, plus those the data type specifications add
my %ERRORS = map { $_ => 1 } qw(
  serverUnavailable serverFail serverPartialFail unknownMethod invalidArguments
  invalidResultReference forbidden accountNotFound accountNotSupportedByMethod
  accountReadOnly requestTooLarge cannotCalculateChanges stateMismatch
  anchorNotFound unsupportedSort unsupportedFilter tooManyChanges fromAccountNotFound
  fromAccountNotSupportedByMethod
);

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] unless $_[0] =~ /^JMAP (?:CMD|REQUEST)|took [\d.]+$/ };

sub call {
  my ($method, $args) = @_;
  my @using = ('urn:ietf:params:jmap:core', map { JMAP::Dispatch::method_capabilities($_) } $method);
  my $r = $api->handle_request({ using => \@using, methodCalls => [[$method, { accountId => 'all', %$args }, 't']] });
  my @resp = grep { ref $_ eq 'ARRAY' && $_->[2] eq 't' } @{ ref $r eq 'HASH' ? $r->{methodResponses} : $r || [] };
  return $resp[0];
}

my %ARGS = (
  'SearchSnippet/get' => { emailIds => [] },
  get           => { ids => [] },
  changes       => { sinceState => '0' },
  query         => {},
  queryChanges  => { sinceQueryState => '0' },
  set           => {},
);

# the parent answers these itself; a worker never sees them
for my $method (grep { !JMAP::Dispatch::is_copy_method($_) && !JMAP::Dispatch::is_push_method($_) }
                JMAP::Dispatch::known_methods()) {
  my ($type, $verb) = split m{/}, $method;
  @warnings = ();
  my $args = $ARGS{$method} // $ARGS{$verb} // {};
  my $resp = eval { call($method, $args) };
  my $what = "$method";
  ok($resp, "$what: answers") or do { diag $@; next };
  if ($resp->[0] eq 'error') {
    my $t = $resp->[1]{type} // '';
    ok($ERRORS{$t} && ($t ne 'serverFail' || ($resp->[1]{description} // '') =~ /no backend/),
       "$what: an error RFC 8620 defines ($t)") or diag explain $resp;
    ok($t ne 'unknownMethod', "$what: is implemented");
  }
  else {
    is($resp->[0], $method, "$what: answers under its own name");
  }
  ok(!$db->in_transaction(), "$what: leaves no transaction open");
  $db->reset();
  is_deeply(\@warnings, [], "$what: warns nothing") or diag @warnings;

  next unless $resp->[0] eq $method;
  my $r = $resp->[1];
  if ($verb eq 'get') {
    is_deeply($r->{list}, [], "$what: no ids, empty list");
    ok(defined $r->{state}, "$what: a state") unless $type =~ /^(?:SearchSnippet|Blob|Principal)$/;
    if (defined $r->{state}) {
      my $c = JMAP::API->can("api_${type}_changes") && call("$type/changes", { sinceState => $r->{state} });
      if ($c && $c->[0] ne 'error') {
        is($c->[1]{newState}, $r->{state}, "$type/changes from the current state: no new state");
        is_deeply([ map { @{ $c->[1]{$_} || [] } } qw(created updated destroyed) ], [], "$type/changes: nothing changed");
      }
      my $s = JMAP::API->can("api_${type}_set") && call("$type/set", {});
      if ($s && $s->[0] ne 'error') {
        is($s->[1]{oldState}, $r->{state}, "$type/set: oldState is the /get state");
        is($s->[1]{newState}, $r->{state}, "$type/set: an empty /set changes no state");
      }
    }
  }
  if ($verb eq 'query' && defined $r->{queryState}) {
    ok(ref $r->{ids} eq 'ARRAY', "$what: ids");
    my $qc = JMAP::API->can("api_${type}_queryChanges") && call("$type/queryChanges", { sinceQueryState => $r->{queryState} });
    if ($qc && $qc->[0] ne 'error') {
      is($qc->[1]{newQueryState}, $r->{queryState}, "$type/queryChanges from the current state: no new state");
      is_deeply([ @{ $qc->[1]{removed} || [] }, @{ $qc->[1]{added} || [] } ], [], "$type/queryChanges: nothing changed");
    }
  }
}

# With data: for each type that can be seeded here, a create, an update
# and a destroy are each reported by /changes as exactly that, whole or a
# change at a time (maxChanges 1).
{
  my %seed = (
    Mailbox       => { table => 'jmailboxes', key => 'jmailboxid', make => sub { $db->dmake('jmailboxes', { jmailboxid => "mb$_[0]", name => "m$_[0]", active => 1 }); "mb$_[0]" } },
    Calendar      => { table => 'jcalendars', key => 'jcalendarid', make => sub { $db->dmake('jcalendars', { name => "c$_[0]", active => 1 }) } },
    AddressBook   => { table => 'jaddressbooks', key => 'jaddressbookid', make => sub { $db->dmake('jaddressbooks', { name => "a$_[0]", active => 1 }) } },
    CalendarEvent => { table => 'jevents', key => 'eventuid', make => sub { $db->set_event([1], { uid => "ev$_[0]", '@type' => 'Event' }); "ev$_[0]" } },
    ContactCard   => { table => 'jcontacts', key => 'contactuid', make => sub { $db->set_card([1], { uid => "k$_[0]", '@type' => 'Card' }); "k$_[0]" } },
  );
  my $n = 0;
  for my $type (sort keys %seed) {
    my $sd = $seed{$type};
    my $state = sub { my $g = call("$type/get", { ids => [] }); $g->[1]{state} };
    $db->begin(); $sd->{make}->(++$n); $db->commit();         # not the first state: that one can't be paged from
    my $s0 = $state->();
    $db->begin(); my $a = $sd->{make}->(++$n); my $b = $sd->{make}->(++$n); my $c = $sd->{make}->(++$n); $db->commit();
    my $s1 = $state->();
    $db->begin(); $db->ddirty($sd->{table}, {}, { $sd->{key} => $b }); $db->commit();
    $db->begin(); $db->ddirty($sd->{table}, { active => 0 }, { $sd->{key} => $c }); $db->commit();
    my $ids = sub { [ sort map { $type eq 'CalendarEvent' ? JMAP::EventId::master_id($_) : "$_" } @_ ] };

    my $all = call("$type/changes", { sinceState => $s0 });
    is_deeply([ map { [ sort @{ $all->[1]{$_} } ] } qw(created updated destroyed) ],
              [ $ids->($a, $b), [], [] ], "$type/changes: created since before them, whatever happened after (S5.2)")
      or diag explain $all;
    my $later = call("$type/changes", { sinceState => $s1 });
    is_deeply([ map { [ sort @{ $later->[1]{$_} } ] } qw(created updated destroyed) ],
              [ [], $ids->($b), $ids->($c) ], "$type/changes: then one updated, one destroyed") or diag explain $later;

    my ($st, %seen, $rounds) = ($s0);
    while (1) {
      my $p = call("$type/changes", { sinceState => $st, maxChanges => 1 });
      last unless ok($p->[0] eq "$type/changes", "$type/changes maxChanges 1: answers") || diag explain $p;
      cmp_ok(scalar(map { @{ $p->[1]{$_} } } qw(created updated destroyed)), '<=', 1, "$type: at most one change");
      $seen{$_}++ for map { @{ $p->[1]{$_} } } qw(created updated);
      $st = $p->[1]{newState};
      last unless $p->[1]{hasMoreChanges};
      last if ++$rounds > 10;
    }
    is_deeply([ sort keys %seen ], $ids->($a, $b), "$type: paged, the same objects arrive");
  }
}

done_testing;
