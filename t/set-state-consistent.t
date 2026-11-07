#!/usr/bin/perl
# RFC 8620: a /set's oldState is "the state string that would have been
# returned by Foo/get before making the requested changes" (S5.3), and
# ifInState is checked against it.  So for every type with a /set, an empty
# /set's oldState must be its /get's state, and ifInState must be checked.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $db = JMAP::ImapDB->new('st');
my $api = JMAP::API->new($db);
{
  no warnings qw(redefine once);
  *JMAP::ImapDB::backend_cmd = sub { die "no backend in this test\n" };
  $db->{$_} = 1 for qw();   # nothing
  for my $sync (qw(sync_calendars sync_addressbooks sync_folders sync_imap sync_files files_root)) {
    no strict 'refs';
    *{"JMAP::ImapDB::$sync"} = sub { return } if JMAP::ImapDB->can($sync);
  }
}
$db->begin(); $db->dmake('jcalendars', { name => 'c', active => 1 }); $db->commit();   # move the states on

my @types = sort map { /^api_(\w+)_set$/ ? $1 : () } grep { JMAP::API->can($_) } keys %JMAP::API::;
for my $type (@types) {
  my $get = JMAP::API->can("api_${type}_get") or next;
  my $set = JMAP::API->can("api_${type}_set");
  my ($g) = eval { $api->$get({ accountId => 'st', ids => [] }) };
  $db->reset();
  next unless ref $g eq 'ARRAY' && $g->[0] ne 'error' && defined $g->[1]{state};
  my ($s) = eval { $api->$set({ accountId => 'st' }) };
  $db->reset();
  next unless ref $s eq 'ARRAY' && $s->[0] ne 'error';
  is($s->[1]{oldState}, $g->[1]{state}, "$type: /set oldState is /get's state");

  my @using = ('urn:ietf:params:jmap:core', map { (JMAP::Dispatch::method_capabilities($_))[0] } "$type/set", "$type/get");
  my $r = $api->handle_request({ using => \@using,
    methodCalls => [["$type/set", { accountId => 'st', ifInState => 'not-the-state',
                                     create => { x => {} } }, 't']] });
  my ($resp) = grep { ref $_ eq 'ARRAY' && $_->[2] eq 't' } @{ ref $r eq 'HASH' ? $r->{methodResponses} : $r };
  is_deeply([ $resp->[0], $resp->[1]{type} ], [ 'error', 'stateMismatch' ], "$type/set: a wrong ifInState is stateMismatch")
    or diag explain $resp;
  $db->reset();
}

# and a /changes from the current state reports that same state
for my $type (sort map { /^api_(\w+)_changes$/ ? $1 : () } grep { JMAP::API->can($_) } keys %JMAP::API::) {
  my $get = JMAP::API->can("api_${type}_get") or next;
  my $chg = JMAP::API->can("api_${type}_changes");
  my ($g) = eval { $api->$get({ accountId => 'st', ids => [] }) };
  $db->reset();
  next unless ref $g eq 'ARRAY' && $g->[0] ne 'error' && defined $g->[1]{state};
  my ($c) = eval { $api->$chg({ accountId => 'st', sinceState => $g->[1]{state} }) };
  $db->reset();
  next unless ref $c eq 'ARRAY' && $c->[0] ne 'error';
  is($c->[1]{newState}, $g->[1]{state}, "$type: /changes newState is /get's state");
}

done_testing;
