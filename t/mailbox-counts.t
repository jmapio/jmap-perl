#!/usr/bin/perl
# Mailbox counts are kept by thread deltas at commit: after every kind of
# change they must equal a full recount.
use strict;
use warnings;
use Test::More;
use JSON ();
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
srand(42);

my $db = JMAP::ImapDB->new('counts');
my @mb = map { "mb$_" } 1 .. 4;
$db->begin(); $db->dmake('jmailboxes', { jmailboxid => $_, name => $_, active => 1 }) for @mb; $db->commit();

sub recount {
  my ($mb) = @_;
  my $q = sub { ($db->dbh->selectrow_array($_[0], {}, $mb))[0] + 0 };
  my $base = "FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1";
  return [ $q->("SELECT COUNT(DISTINCT msgid) $base"),
           $q->("SELECT COUNT(DISTINCT msgid) $base AND isUnread = 1 AND NOT isDraft"),
           $q->("SELECT COUNT(DISTINCT thrid) $base"),
           $q->("SELECT COUNT(DISTINCT thrid) $base AND thrid IN (SELECT thrid FROM jmessages JOIN jmessagemap USING (msgid)"
              . " WHERE isUnread = 1 AND NOT isDraft AND jmessages.active = 1 AND jmessagemap.active = 1)") ];
}
sub check {
  my ($what) = @_;
  $db->begin();
  for my $m (@mb) {
    my $row = $db->dgetone('jmailboxes', { jmailboxid => $m }, 'totalEmails,unreadEmails,totalThreads,unreadThreads');
    my $got = [ map { 0 + ($row->{$_} // 0) } qw(totalEmails unreadEmails totalThreads unreadThreads) ];
    my $want = recount($m);
    unless (is_deeply($got, $want, "$what: $m")) { $db->commit(); return 0 }
  }
  $db->commit();
  return 1;
}

my (%live, $n);
for my $step (1 .. 300) {
  my $op = int rand 6;
  $db->begin();
  my @ids = sort keys %live;
  if ($op <= 1 || !@ids) {             # a new message, in one or two mailboxes, in one of 25 threads
    my $id = 'msg' . ++$n;
    my @in = do { my %x = map { $mb[int rand @mb] => 1 } 1 .. 1 + int rand 2; sort keys %x };
    my $kw = { (rand() < .5 ? ('$seen' => 1) : ()), (rand() < .1 ? ('$draft' => 1) : ()) };
    $db->add_message({ msgid => $id, thrid => 'thr' . int(rand 25), internaldate => $step, keywords => $kw,
                       isDraft => $kw->{'$draft'} ? 1 : 0, isUnread => $kw->{'$seen'} ? 0 : 1 }, \@in);
    $live{$id} = 1;
  }
  elsif ($op == 2) {                    # flags and mailboxes change
    my $id = $ids[int rand @ids];
    my @in = do { my %x = map { $mb[int rand @mb] => 1 } 1 .. 1 + int rand 2; sort keys %x };
    $db->change_message($id, { keywords => { (rand() < .5 ? ('$seen' => JSON::true) : ()), (rand() < .1 ? ('$draft' => JSON::true) : ()) } }, \@in);
  }
  elsif ($op == 3) {                    # out of one mailbox
    my $id = $ids[int rand @ids];
    $db->delete_message_from_mailbox($id, $mb[int rand @mb]);
  }
  elsif ($op == 4) {                    # into another
    my $id = $ids[int rand @ids];
    my $m = $mb[int rand @mb];
    $db->add_message_to_mailbox($id, $m) unless $db->dgetone('jmessagemap', { msgid => $id, jmailboxid => $m, active => 1 });
  }
  else {                                # gone
    my $id = $ids[int rand @ids];
    $db->delete_message($id);
    delete $live{$id};
  }
  $db->commit();
  last unless check("step $step (op $op)");
}

done_testing;
