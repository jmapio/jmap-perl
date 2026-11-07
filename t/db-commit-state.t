#!/usr/bin/perl
# commit saves jhighestmodseq and the per-type states whether or not anyone
# is listening (change_cb). A worker without one (after an OAuth signup, the
# backfill worker) used to change rows without moving the state, so
# /changes from the old state saw nothing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;

for my $cb (0, 1) {
  my $db = JMAP::ImapDB->new("state$cb");
  my @told;
  $db->{change_cb} = sub { push @told, $_[2] } if $cb;
  $db->begin();
  my $before = $db->get_user();
  my ($m0, $s0) = ($before->{jhighestmodseq}, $before->{jstateMailbox});
  $db->commit();

  $db->begin();
  $db->dmake('jmailboxes', { name => 'Box', active => 1 });
  $db->commit();

  $db->begin();
  my $after = $db->get_user();
  $db->commit();
  my $what = $cb ? 'with change_cb' : 'without change_cb';
  cmp_ok($after->{jhighestmodseq}, '>', $m0, "$what: jhighestmodseq moves");
  isnt($after->{jstateMailbox}, $s0, "$what: the Mailbox state moves");
  is($after->{jstateMailbox}, "$after->{jhighestmodseq}", "$what: to the new modseq");
  is_deeply(\@told, $cb ? ["$after->{jhighestmodseq}"] : [], "$what: told only if listening");
}

done_testing;
