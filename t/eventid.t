#!/usr/bin/perl
# t/eventid.t -- JMAP::EventId: every CalendarEvent id is a valid RFC 8620
# Id, and leads back to the UID (and recurrence id) it was made from.
use strict;
use warnings;
use utf8;
use Test::More;
use lib '.';

use JMAP::EventId;

my $VALID = qr/\A[A-Za-z0-9_-]{1,255}\z/;
my $mid   = \&JMAP::EventId::master_id;
my $iid   = \&JMAP::EventId::instance_id;
my $parse = \&JMAP::EventId::parse_id;

# The resolver a caller builds: hashed ids are looked up among known UIDs.
sub resolve {
  my ($id, @uids) = @_;
  my ($event, $rid) = $parse->($id);
  return () unless defined $event;
  my %hashed = map { $mid->($_) => $_ } grep { $mid->($_) ne $_ } @uids;
  my $uid = JMAP::EventId::is_hashed($event) ? $hashed{$event} : $event;
  return () unless defined $uid && JMAP::EventId::event_id($uid, $rid) eq $id;
  return defined $rid ? ($uid, $rid) : ($uid);
}

# A UID that already is a valid Id keeps it.
for my $uid ('81316bb8-3d13-4138-9425-1acd4d20bfa7', '9Q1NG6YTQJcHLL7hvVp62',
             '040000008200E00074C5B7101A82E00800000000A013AD04150BD801',
             'a', 'x' x 200, '-dash_first') {
  is($mid->($uid), $uid, "plain UID kept: " . substr($uid, 0, 40));
  is_deeply([ $parse->($uid) ], [ $uid ], 'and parses as an event');
}

# Any other UID is hashed into a valid Id.
my @odd = ('20270126-pa1-portfolio@semester', 'abc123@google.com', 'http://example.com/e/1',
           'urn:uuid:1234', 'x' x 201, '_leading-underscore', '_r20261107_x', '_h' . ('A' x 43),
           'has space', 'Persönlich@x', '');
my %seen;
for my $uid (@odd) {
  my $id = $mid->($uid);
  like($id, $VALID, "hashed id is valid: '$uid'");
  ok(JMAP::EventId::is_hashed($id), 'and has the hashed shape');
  is(length $id, 45, 'and is 45 characters');
  is($mid->($uid), $id, 'and is stable');
  ok(!$seen{$id}++, 'and differs from the others');
  is_deeply([ resolve($id, @odd) ], [ $uid ], 'and resolves back to the UID');
}

# A client's UID (characters, as JSON decoding gives them) and the UTF-8
# octets DBD::SQLite returns for it give the same id.
{
  my $octets = "caf\xc3\xa9\@example.com";
  my $chars = $octets;
  utf8::decode($chars);
  ok(utf8::is_utf8($chars), 'decoded UID is a character string');
  is($mid->($chars), $mid->($octets), 'non-ASCII UID: characters and octets agree');
}

# Instances of a recurring event
{
  my $plain = '81316bb8-3d13-4138-9425-1acd4d20bfa7';
  is($iid->($plain, '2026-11-07T09:30:00'), "_r20261107T093000_$plain", 'instance of a plain UID');
  is($iid->($plain, '2026-11-07'), "_r20261107_$plain", 'instance of an all-day series');

  for my $uid ($plain, '20270126-pa1-portfolio@semester', 'x' x 200, 'x' x 400) {
    for my $rid ('2026-11-07T09:30:00', '2026-11-07', '2026-11-07T09:30:00.5', 'weird rid') {
      my $id = $iid->($uid, $rid);
      like($id, $VALID, "instance id is valid ($rid)");
      ok(!JMAP::EventId::is_hashed($id), 'and is not taken for an event');
      is_deeply([ resolve($id, $uid) ], [ $uid, $rid ], 'and resolves to UID and recurrence id');
    }
  }
}

# Shapes that are not ids we hand out
is_deeply([ $parse->(undef) ], [], 'undef is nothing');
is_deeply([ $parse->('') ], [], 'empty is nothing');
is_deeply([ resolve('abc123@google.com', 'abc123@google.com') ], [],
          'a raw UID that is not its own id does not resolve');
is_deeply([ resolve('_h' . ('A' x 43), 'abc123@google.com') ], [], 'an unknown hash does not resolve');
is_deeply([ resolve('81316bb8/2026-11-07T00:00:00', '81316bb8') ], [],
          'the old "uid/recurrenceId" form does not resolve');
is_deeply([ resolve('_r20261107T093000_abc', 'abc') ], [ 'abc', '2026-11-07T09:30:00' ],
          'an instance id resolves without a lookup when the UID is plain');

# RFC 8620 S1.2: no id longer than 255
{
  my $uid = 'a' x 200;
  my $id = JMAP::EventId::instance_id($uid, 'not-a-date-' . ('x' x 40));
  ok(defined $id && length $id <= 255, 'a long instance id falls back to the hashed event id');
  like($id, qr/_h[A-Za-z0-9_-]{43}\z/, '... which it ends with');
  is(JMAP::EventId::instance_id($uid, 'y' x 200), undef, 'one too long even so gets no id');
  is(JMAP::EventId::hash_id('abc'), JMAP::EventId::hash_id('abc'), 'hash_id is stable');
  isnt(JMAP::EventId::master_id('abc'), JMAP::EventId::hash_id('abc'), 'a plain UID keeps its own id');
}

done_testing;
