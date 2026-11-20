#!/usr/bin/perl
# Email/query answers the common shapes in SQL -- inMailbox,
# inMailboxOtherThan, hasKeyword and notKeyword, alone or ANDed, sorted by
# receivedAt and hasKeyword -- and every other query in Perl.  The two must
# agree exactly: same ids, same order (ties broken by id), same total, with
# and without collapseThreads -- and so must Email/queryChanges.
use strict;
use warnings;
use Test::More;
use JSON ();
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;
srand(7);

my $db = JMAP::ImapDB->new('fast');
my $api = JMAP::API->new($db);
my @mb = map { "mb$_" } 1 .. 3;
$db->begin(); $db->dmake('jmailboxes', { jmailboxid => $_, name => $_, active => 1 }) for @mb; $db->commit();

# 400 messages in 60 threads, many sharing a date (ties), some later removed
for my $n (1 .. 400) {
  my @in = do { my %x = map { $mb[int rand @mb] => 1 } 1 .. 1 + int rand 2; sort keys %x };
  $db->begin();
  my %kw = map { $_ => JSON::true } grep { rand() < 0.3 } qw($seen $flagged $pinned);
  $db->add_message({ msgid => sprintf('M%x', int rand 1e9) . "_$n", thrid => 'T' . int(rand 60),
                     internaldate => 1700000000 + int(rand 50), keywords => \%kw, isDraft => 0, isUnread => 1 }, \@in);
  $db->commit();
}
$db->begin();
my $ids = $db->dgetcol('jmessages', {}, 'msgid');
$db->delete_message($ids->[$_ * 7]) for 0 .. 20;
$db->delete_message_from_mailbox($ids->[$_ * 11 + 1], 'mb1') for 0 .. 20;
# a map row with no mailbox puts its message in none: not "another mailbox"
$db->dbh->do('INSERT INTO jmessagemap (jmailboxid, msgid, active) VALUES (NULL, ?, 1)', {}, $ids->[$_ * 13 + 2]) for 0 .. 10;
$db->commit();

sub run {
  my ($meth, $args, $slow) = @_;
  local $ENV{JMAP_NO_QUERY_FASTPATH} = $slow ? 1 : undef;
  my ($r) = $api->$meth({ accountId => 'fast', %$args });
  return $r;
}

my @filters = (undef, map { { inMailbox => $_ } } @mb, 'nosuch');
my @sorts = (undef, [], [{ property => 'receivedAt' }], [{ property => 'receivedAt', isAscending => JSON::false }],
             [{ property => 'receivedAt', isAscending => JSON::true }]);
for my $f (@filters) {
  for my $s (@sorts) {
    for my $c (0, 1) {
      my %args = ((defined $f ? (filter => $f) : ()), (defined $s ? (sort => $s) : ()), collapseThreads => $c ? JSON::true : JSON::false);
      my $name = JSON->new->canonical->encode(\%args);
      my $fast = run('api_Email_query', \%args, 0);
      my $slow = run('api_Email_query', \%args, 1);
      is($fast->[0], 'Email/query', "answers: $name") or diag explain $fast;
      is_deeply([@{$fast->[1]}{qw(ids total)}], [@{$slow->[1]}{qw(ids total)}], "same as Perl: $name");
    }
  }
}
ok(@{ run('api_Email_query', { filter => { inMailbox => 'mb2' } }, 0)->[1]{ids} } > 50, 'the fixture lists something');

# what webmail clients send besides a listing (bulwark): keywords, mailboxes
# left out, ANDed, and pinned-first sorts
sub fast_path {
  $db->begin();
  my $rows = $api->_email_query_fast(shift);
  $db->commit();
  return $rows;
}
my $pinned = { property => 'hasKeyword', keyword => '$pinned', isAscending => JSON::false };
my @shapes = (
  { filter => { hasKeyword => '$flagged' } },
  { filter => { notKeyword => '$seen' } },
  { filter => { inMailboxOtherThan => ['mb1'] } },
  { filter => { inMailboxOtherThan => ['mb1', 'mb3'] } },
  { filter => { inMailboxOtherThan => [] } },
  { filter => { inMailbox => 'mb2', notKeyword => '$seen' } },
  { filter => { operator => 'AND', conditions => [{ inMailbox => 'mb2' }, { notKeyword => '$seen' }, { inMailboxOtherThan => ['mb1'] }] } },
  { filter => { operator => 'AND', conditions => [{ hasKeyword => '$pinned' }, { inMailboxOtherThan => ['mb3', 'nosuch'] }] } },
  { filter => { operator => 'AND', conditions => [] } },
  { filter => { inMailbox => 'mb1' }, sort => [$pinned, { property => 'receivedAt', isAscending => JSON::false }] },
  { sort => [{ property => 'hasKeyword', keyword => '$seen' }, { property => 'receivedAt' }] },
  { sort => [$pinned, { property => 'hasKeyword', keyword => '$flagged', isAscending => JSON::false }] },
  { filter => { notKeyword => '$nosuch' }, sort => [{ property => 'hasKeyword', keyword => '$nosuch' }] },
);
for my $shape (@shapes) {
  for my $c (0, 1) {
    my %args = (%$shape, collapseThreads => $c ? JSON::true : JSON::false);
    my $name = JSON->new->canonical->encode(\%args);
    ok(fast_path(\%args), "takes the SQL path: $name");
    my $fast = run('api_Email_query', \%args, 0);
    my $slow = run('api_Email_query', \%args, 1);
    is($fast->[0], 'Email/query', "answers: $name") or diag explain $fast;
    is_deeply([@{$fast->[1]}{qw(ids total)}], [@{$slow->[1]}{qw(ids total)}], "same as Perl: $name");
  }
}

# and what it cannot answer is left to Perl
for my $other ({ filter => { operator => 'OR', conditions => [{ inMailbox => 'mb1' }] } },
               { filter => { from => 'x' } },
               { filter => { hasKeyword => 'a"b' } },
               { sort => [{ property => 'subject' }] }) {
  ok(!fast_path($other), 'not the SQL path: ' . JSON->new->canonical->encode($other));
}

# queryChanges: a snapshot from one path, the diff from the other, both ways
for my $first (0, 1) {
  my %args = (filter => { inMailbox => 'mb2' }, sort => [{ property => 'receivedAt', isAscending => JSON::false }]);
  my $q = run('api_Email_query', \%args, $first);
  $db->begin();
  $db->add_message({ msgid => "new$first", thrid => 'T1', internaldate => 1700000025, keywords => {}, isDraft => 0, isUnread => 1 }, ['mb2']);
  $db->commit();
  my $fast = run('api_Email_queryChanges', { %args, sinceQueryState => $q->[1]{queryState} }, !$first);
  is($fast->[0], 'Email/queryChanges', "queryChanges answers ($first)") or diag explain $fast;
  is_deeply([map { $_->{id} } @{ $fast->[1]{added} }], ["new$first"], "the new message is added ($first)");
  my $now = run('api_Email_query', \%args, $first);
  my ($at) = grep { $now->[1]{ids}[$_] eq "new$first" } 0 .. $#{ $now->[1]{ids} };
  is($fast->[1]{added}[0]{index}, $at, "at its place ($first)");
}

done_testing;
