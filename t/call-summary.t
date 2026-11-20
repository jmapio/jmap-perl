#!/usr/bin/perl
# JMAP_LOG_CALLS: the shape of each call's arguments and the size of its
# answer, never what is in them.
use strict;
use warnings;
use Test::More;
use JSON::XS ();
use lib '.';
use JMAP::CallSummary;

my $true = JSON::XS::true;

is(JMAP::CallSummary::args({
  accountId => 'a1',
  filter => { operator => 'AND', conditions => [
    { inMailbox => 'mb1' }, { notKeyword => '$seen' }, { inMailboxOtherThan => ['t', 'j'] } ] },
  sort => [{ property => 'hasKeyword', keyword => '$pinned', isAscending => JSON::XS::false },
           { property => 'receivedAt', isAscending => JSON::XS::false }],
  position => 0, limit => 50, calculateTotal => $true, collapseThreads => $true,
}), 'filter=AND({inMailbox=mb1},{notKeyword=$seen},{inMailboxOtherThan=[2]})'
  . ' sort=[hasKeyword:$pinned desc,receivedAt desc] position=0 limit=50 calculateTotal collapseThreads',
  'a webmail folder list: everything about its shape');

is(JMAP::CallSummary::args({
  filter => { after => '2026-10-26T00:00:00', before => '2026-12-07T00:00:00', inCalendars => ['c1', 'c2'] },
  expandRecurrences => $true, timeZone => 'Australia/Melbourne',
}), 'filter={after=2026-10-26T00:00:00,before=2026-12-07T00:00:00,inCalendars=[2]} expandRecurrences timeZone=Australia/Melbourne',
  'a calendar range');

# nothing anyone wrote, or who they are
my $private = JMAP::CallSummary::args({
  filter => { operator => 'OR', conditions => [
    { text => 'my secret plans' }, { from => 'alice@example.com' }, { subject => 'Re: divorce' },
    { uid => 'abc@host' }, { header => ['X-Thing', 'value'] } ] },
});
is($private, 'filter=OR({text=<15>},{from=<17>},{subject=<11>},{uid=<8>},{header=[2]})', 'search terms only as lengths');
unlike($private, qr/secret|alice|divorce|abc\@|X-Thing/, 'none of it in the line');

is(JMAP::CallSummary::args({ sinceState => 's9', maxChanges => 500 }), 'maxChanges=500 since', '/changes');
is(JMAP::CallSummary::args({ create => { a => {}, b => {} }, update => { x => { subject => 'hi' } }, destroy => ['1', '2', '3'] }),
   'create=2 update=1 destroy=3', '/set: how much, not what');
is(JMAP::CallSummary::args({ '#ids' => { resultOf => 'q', name => 'Email/query', path => '/ids' } }), '#ids',
   'a back-reference');

is(JMAP::CallSummary::result(['Email/query', { ids => [1 .. 50], total => 36725, position => 0 }]),
   'ids=50 total=36725', 'a query answer');
is(JMAP::CallSummary::result(['CalendarEvent/get', { list => [{}, {}, {}], notFound => ['x'], state => 's' }]),
   'list=3 notFound=1', 'a get answer');
is(JMAP::CallSummary::result(['Email/set', { created => { a => {} }, updated => { x => undef, y => undef }, destroyed => ['z'], notCreated => { b => {} } }]),
   'created=1 updated=2 destroyed=1 notCreated=1', 'a set answer');
is(JMAP::CallSummary::result(['Email/changes', { created => [], updated => [1], destroyed => [], hasMoreChanges => $true }]),
   'created=0 updated=1 destroyed=0 more', 'a changes answer');
is(JMAP::CallSummary::result(['error', { type => 'requestTooLarge' }]), 'error=requestTooLarge', 'an error');
is(JMAP::CallSummary::result(['Email/copy', { created => { a => {} } }], ['Email/set', { destroyed => ['a'] }]),
   'Email/copy: created=1; Email/set: destroyed=1', 'two answers, each named');

# looking must not change what it looks at: a number it put into the line
# went out as a string ("total": "5")
{
  # counted at run time, as the methods' answers are: a literal is kept
  # differently by perl, and passed with the bug
  my @found = (1 .. 5);
  my ($one, $fifty, $back, $ten) = map { $_ - 0 } (scalar(@found) - 4, 50, -1, 10);
  my $answer = ['Email/query', { total => scalar(@found), position => $one, ids => ['a'] }];
  my $args = { position => $one, limit => $fifty, anchorOffset => $back, maxChanges => $ten };
  JMAP::CallSummary::result($answer);
  JMAP::CallSummary::args($args);
  my $json = JSON::XS->new->canonical;
  is($json->encode($answer->[1]), '{"ids":["a"],"position":1,"total":5}', 'the answer still encodes its numbers as numbers');
  is($json->encode($args), '{"anchorOffset":-1,"limit":50,"maxChanges":10,"position":1}', 'and so do the arguments');
}

done_testing;
