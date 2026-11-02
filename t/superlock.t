#!/usr/bin/perl

use strict;
use warnings;
use Test::More;

use lib '.';

use Fcntl qw(:flock);
use File::Temp qw(tempdir);
use POSIX ();

BEGIN { $ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1) }

use JMAP::DB;

my $db = bless { accountid => 'a1' }, 'JMAP::DB';
my $lockfile = "$ENV{JMAP_DATADIR}/a1.lock";

# A second flock on the same file waits even within one process, so each case
# runs in a child that SIGALRM kills if it gets stuck.
sub finishes {
  my ($code) = @_;
  my $pid = fork() // die "fork: $!";
  unless ($pid) {
    alarm 5;
    POSIX::_exit($code->() ? 0 : 1);
  }
  waitpid($pid, 0);
  return $? == 0;
}

sub lock_is_free {
  open(my $fh, '>', $lockfile) or die "open: $!";
  return flock($fh, LOCK_EX | LOCK_NB);
}

# EmailSubmission/set still holds the lock when onSuccessUpdateEmail runs Email/set
ok(finishes(sub {
  my $outer = $db->begin_superlock();
  my $inner = $db->begin_superlock();
  return 1;
}), 'taking the lock again in the same process does not wait on itself');

ok(finishes(sub {
  my $outer = $db->begin_superlock();
  { my $inner = $db->begin_superlock(); }
  return 0 if lock_is_free();
  undef $outer;
  return lock_is_free();
}), 'the lock is held until the outermost holder lets go');

done_testing();
