package JMAP::Workers;
use strict;
use warnings;

# The parent's worker-table policy: which workers survive an error, which
# requests count as use, and which idle workers to reap.  Pure, like
# JMAP::Dispatch: no I/O and no AnyEvent; t/workers.t covers it.

# The accounts worker answers ['error', ...] and carries on (its loop does
# `next`); every other worker exits after one (`last`), so the parent must
# drop its handle and fail whatever was queued behind the failed request.
sub survives_error {
  my ($name) = @_;
  return $name eq '__accounts__' ? 1 : 0;
}

# Requests the parent makes on its own timers (the periodic sync) are not
# use: if they refreshed last_active, every worker would look busy forever
# and none would ever be reaped.
my %BACKGROUND = map { $_ => 1 } qw(sync);
sub is_background { return $BACKGROUND{ $_[0] // '' } ? 1 : 0 }

# The workers to close, given:
#   now, timeout          seconds
#   last_active           { name => epoch }
#   busy                  { name => 1 }  requests in flight
#   keep                  { accountid => 1 }  must stay up: an EventSource
#                         client or a push subscription is waiting on its
#                         changes, or a backfill is running
# The accounts worker is never reaped.  A sub-worker ("$accountid:backfill")
# is kept with its account.
sub reapable {
  my (%a) = @_;
  my @out;
  for my $name (sort keys %{ $a{last_active} }) {
    next if $name eq '__accounts__';
    next if $a{busy}{$name};
    (my $accountid = $name) =~ s/:[^:]+$//;
    next if $a{keep}{$accountid};
    next unless $a{now} - ($a{last_active}{$name} || 0) > $a{timeout};
    push @out, $name;
  }
  return @out;
}

1;
