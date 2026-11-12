#!/usr/bin/perl
# t/dav-collection-sync.t -- ImapDB::sync_calendars and sync_addressbooks against
# a fake CalDAV/CardDAV server (backend_cmd replaced): every collection's sync
# token lands on its own row, and a collection the server will not sync costs
# the other collections nothing and loses none of its own items.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;

sub ical {
  my ($uid) = @_;
  join("\r\n", 'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//jmap-proxy test//EN',
    'BEGIN:VEVENT', "UID:$uid", 'DTSTAMP:20261101T000000Z', 'DTSTART:20261105T100000Z',
    'DTEND:20261105T110000Z', "SUMMARY:$uid", 'END:VEVENT', 'END:VCALENDAR', '');
}
sub vcard {
  my ($uid) = @_;
  join("\r\n", 'BEGIN:VCARD', 'VERSION:3.0', "UID:$uid", "FN:$uid", "N:$uid;;;;", 'END:VCARD', '');
}

# the fake server: collection href => { name, token, items => { href => [etag, data] },
#   broken (every request dies), nolisting (a listing without a token comes back
#   empty, by REPORT and by PROPFIND), reportless (a sync-collection REPORT without
#   a token dies, as Google's does, but PROPFIND lists and has the token) }
my (%cals, %books, %calls);

sub links {
  my ($colls, $href, $token) = @_;
  my $c = $colls->{$href} or die "no collection $href\n";
  die "REPORT failed\n" if $c->{broken};
  if (defined $token and length $token) {
    die "invalid sync token\n" unless $token eq $c->{token};
    return ({}, [], [], $c->{token});
  }
  die "400 INVALID_ARGUMENT\n" if $c->{reportless};
  return if $c->{nolisting};
  return ({ map { $_ => $c->{items}{$_}[0] } keys %{$c->{items}} }, [], [], $c->{token});
}
# PROPFIND: the collection's links and its DAV:sync-token
sub propfind {
  my ($colls, $href) = @_;
  my $c = $colls->{$href} or die "no collection $href\n";
  die "PROPFIND failed\n" if $c->{broken};
  return if $c->{nolisting};
  return ({ map { $_ => $c->{items}{$_}[0] } keys %{$c->{items}} }, $c->{token});
}
sub multi {
  my ($colls, $href, $hrefs) = @_;
  my $items = $colls->{$href}{items};
  return ({ map { $_ => $items->{$_}[1] } @$hrefs }, [], { map { $_ => $items->{$_}[0] } @$hrefs });
}
sub listing {
  my ($colls) = @_;
  return [ map { +{ href => $_, name => $colls->{$_}{name}, color => '#336699',
                    isReadOnly => 0, syncToken => $colls->{$_}{token} } } sort keys %$colls ];
}

no warnings qw(redefine once);
*JMAP::ImapDB::backend_cmd = sub {
  my ($Self, $cmd, @args) = @_;
  die "in transaction\n" if $Self->in_transaction();
  $calls{$cmd}++;
  $calls{"$cmd $args[0]"}++ if @args;
  return listing(\%cals)        if $cmd eq 'get_calendars';
  return listing(\%books)       if $cmd eq 'get_addressbooks';
  return links(\%cals, @args)   if $cmd eq 'sync_event_links';
  return links(\%books, @args)  if $cmd eq 'sync_card_links';
  return propfind(\%cals, @args)  if $cmd eq 'list_event_links';
  return propfind(\%books, @args) if $cmd eq 'list_card_links';
  return multi(\%cals, @args)   if $cmd eq 'get_events_multi';
  return multi(\%books, @args)  if $cmd eq 'get_cards_multi';
  die "unexpected $cmd\n";
};
use warnings 'redefine';

my $db = JMAP::ImapDB->new('davsynctest');
$db->{change_cb} = sub {};

sub rows {
  my ($table) = @_;
  $db->begin();
  my $r = { map { $_->{href} => $_ } @{ $db->dget($table, {}) } };
  $db->commit();
  return $r;
}
sub events_in {
  my ($href) = @_;
  $db->begin();
  my $jid = $db->dgetfield('icalendars', { href => $href }, 'jcalendarid');
  my $uids = $db->dgetcol('jevents', { jcalendarid => $jid, active => 1 }, 'eventuid');
  $db->commit();
  return [ sort @$uids ];
}
sub cards_in {
  my ($href) = @_;
  $db->begin();
  my $jid = $db->dgetfield('iaddressbooks', { href => $href }, 'jaddressbookid');
  my $uids = $db->dgetcol('jcontacts', { jaddressbookid => $jid, active => 1 }, 'contactuid');
  $db->commit();
  return [ sort @$uids ];
}
# runs a sync, returning what it warned; a sync that dies fails the test
sub quietly {
  my ($what, $sync) = @_;
  my $warned = '';
  local $SIG{__WARN__} = sub { $warned .= $_[0] };
  ok(eval { $db->$sync(); 1 }, "$what: the sync completes") or diag $@;
  return $warned;
}

# --- calendars: the token goes on the calendar's own row
%cals = (
  '/cal/a/' => { name => 'A', token => 'a1', items => { '/cal/a/1.ics' => ['ea1', ical('a-1')] } },
  '/cal/b/' => { name => 'B', token => 'b1', items => { '/cal/b/1.ics' => ['eb1', ical('b-1')] } },
);
quietly('first calendar sync', 'sync_calendars');
# B goes, then C comes: C reuses B's icalendarid (that row was deleted) but gets
# a new jcalendarid (jcalendars rows are only deactivated), so the two differ
delete $cals{'/cal/b/'};
quietly('calendar removed', 'sync_calendars');
$cals{'/cal/c/'} = { name => 'C', token => 'c1', items => { '/cal/c/1.ics' => ['ec1', ical('c-1')] } };
quietly('calendar added', 'sync_calendars');
my $ical = rows('icalendars');
isnt($ical->{'/cal/c/'}{icalendarid}, $ical->{'/cal/c/'}{jcalendarid},
  'precondition: the new calendar has different icalendarid and jcalendarid');
is($ical->{'/cal/a/'}{syncToken}, 'a1', 'calendar A keeps its own token');
is($ical->{'/cal/c/'}{syncToken}, 'c1', 'calendar C has its own token');
is_deeply(events_in('/cal/c/'), ['c-1'], 'calendar C has its event');

%calls = ();
quietly('nothing changed', 'sync_calendars');
is($calls{sync_event_links} // 0, 0, 'calendars whose token matches are not asked again');

# --- one calendar the server will not sync costs the others nothing
$cals{'/cal/a/'}{token} = 'a2';
$cals{'/cal/a/'}{items}{'/cal/a/2.ics'} = ['ea2', ical('a-2')];
$cals{'/cal/d/'} = { name => 'D', token => 'd1', broken => 1,
                     items => { '/cal/d/1.ics' => ['ed1', ical('d-1')] } };
my $warned = quietly('one calendar broken', 'sync_calendars');
is_deeply(events_in('/cal/a/'), ['a-1', 'a-2'], 'the other calendars still get their changes');
$ical = rows('icalendars');
ok($ical->{'/cal/d/'}, 'the broken calendar is still listed');
ok(!$ical->{'/cal/d/'}{syncToken}, 'but holds no token, so the next sync tries it again');
like($warned, qr{calendar sync of /cal/d/ failed}, 'and the failure is logged');

delete $cals{'/cal/d/'}{broken};
quietly('calendar repaired', 'sync_calendars');
is_deeply(events_in('/cal/d/'), ['d-1'], 'once the server answers, its events arrive');

# --- a full listing that never came removes nothing
$cals{'/cal/a/'}{token} = 'a3';
$cals{'/cal/a/'}{nolisting} = 1;
quietly('calendar listing missing', 'sync_calendars');
is_deeply(events_in('/cal/a/'), ['a-1', 'a-2'], 'its events are kept');
is(rows('icalendars')->{'/cal/a/'}{syncToken}, 'a2', 'and so is its old token');

# --- address books: the same two rules
%books = (
  '/ab/x/' => { name => 'X', token => 'x1', items => { '/ab/x/1.vcf' => ['ex1', vcard('x-1')] } },
  '/ab/y/' => { name => 'Y', token => 'y1', items => { '/ab/y/1.vcf' => ['ey1', vcard('y-1')] } },
);
quietly('first address book sync', 'sync_addressbooks');
delete $books{'/ab/y/'};
quietly('address book removed', 'sync_addressbooks');
$books{'/ab/z/'} = { name => 'Z', token => 'z1', items => { '/ab/z/1.vcf' => ['ez1', vcard('z-1')] } };
quietly('address book added', 'sync_addressbooks');
my $iab = rows('iaddressbooks');
isnt($iab->{'/ab/z/'}{iaddressbookid}, $iab->{'/ab/z/'}{jaddressbookid},
  'precondition: the new address book has different iaddressbookid and jaddressbookid');
is($iab->{'/ab/x/'}{syncToken}, 'x1', 'address book X keeps its own token');
is($iab->{'/ab/z/'}{syncToken}, 'z1', 'address book Z has its own token');
is_deeply(cards_in('/ab/z/'), ['z-1'], 'address book Z has its card');

# every REPORT on X now fails: its cards must not be taken for removed
$books{'/ab/x/'}{token} = 'x2';
$books{'/ab/x/'}{broken} = 1;
$books{'/ab/z/'}{token} = 'z2';
$books{'/ab/z/'}{items}{'/ab/z/2.vcf'} = ['ez2', vcard('z-2')];
$warned = quietly('one address book broken', 'sync_addressbooks');
is_deeply(cards_in('/ab/x/'), ['x-1'], 'the broken address book keeps its cards');
is(rows('iaddressbooks')->{'/ab/x/'}{syncToken}, 'x1', 'and its old token');
is_deeply(cards_in('/ab/z/'), ['z-1', 'z-2'], 'the other address book still gets its changes');
like($warned, qr{address book sync of /ab/x/ failed}, 'and the failure is logged');

# --- a server that will not start a sync without a token (Google): the
# collection is listed by PROPFIND, and its listed token is kept, so the next
# sync is a sync-collection from that token instead of another listing
$books{'/ab/g/'} = { name => 'G', token => 'g1', reportless => 1,
                     items => { '/ab/g/1.vcf' => ['eg1', vcard('g-1')], '/ab/g/2.vcf' => ['eg2', vcard('g-2')] } };
$warned = quietly('address book refusing a token-less sync', 'sync_addressbooks');
is_deeply(cards_in('/ab/g/'), ['g-1', 'g-2'], 'its cards arrive by listing');
is(rows('iaddressbooks')->{'/ab/g/'}{syncToken}, 'g1', 'and it keeps the token it lists');
unlike($warned, qr{/ab/g/}, 'with nothing logged');
%calls = ();
quietly('address book synced from its listed token', 'sync_addressbooks');
is($calls{"list_card_links /ab/g/"} // 0, 0, 'the next sync does not list again');
is_deeply(cards_in('/ab/g/'), ['g-1', 'g-2'], 'and keeps its cards');

# the same for a calendar, whose stored token the server has also forgotten
$cals{'/cal/g/'} = { name => 'G', token => 'g1', reportless => 1,
                     items => { '/cal/g/1.ics' => ['eg1', ical('g-1')] } };
quietly('calendar refusing a token-less sync', 'sync_calendars');
is_deeply(events_in('/cal/g/'), ['g-1'], 'its events arrive by listing');
is(rows('icalendars')->{'/cal/g/'}{syncToken}, 'g1', 'and it keeps the token it lists');
$cals{'/cal/g/'}{token} = 'g2';   # g1 is no longer valid
delete $cals{'/cal/g/'}{items}{'/cal/g/1.ics'};
$cals{'/cal/g/'}{items}{'/cal/g/2.ics'} = ['eg2', ical('g-2')];
quietly('calendar whose token expired', 'sync_calendars');
is_deeply(events_in('/cal/g/'), ['g-2'], 'a fresh listing finds what came and what went');
is(rows('icalendars')->{'/cal/g/'}{syncToken}, 'g2', 'and the new token is kept');

done_testing();
