#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::QueryChanges;

# The removed and added lists of a /queryChanges response (RFC 8620 S5.6),
# from the snapshot of the old results and the new results. Pure: no I/O,
# no DB; t/query-changes.t covers it.
#
#   my ($removed, $added) = JMAP::QueryChanges::diff(\@old_ids, \@new_ids, \%changed);
#
# An id is reported -- in removed, and again in added if it is still there --
# when it
#   - left the results (removed only) or joined them (added only);
#   - is in %changed: the caller's set of results whose sort or filter
#     properties may have changed. RFC 8620 S5.6 says the server MUST include
#     those when the sort or filter is on a mutable property;
#   - moved relative to the others without changing itself (with sortAsTree,
#     renaming a parent moves its children). Only the fewest such ids are
#     reported: those outside the longest run that kept its old order. So one
#     insertion near the top doesn't re-report everything after it.
#
# Splicing removed out of the old list, then the added items in at their
# indexes in ascending order, gives exactly the new list. added is sorted by
# index, as the RFC requires.
sub diff {
  my ($old_ids, $new_ids, $changed) = @_;
  $changed ||= {};

  my %old_idx;
  $old_idx{$old_ids->[$_]} = $_ for 0 .. $#$old_ids;
  my %new_set = map { $_ => 1 } @$new_ids;

  # Ids that stay and didn't change, in new order, with their old indexes;
  # those in the longest increasing run of old indexes keep their place.
  my @stay = grep { exists $old_idx{$_} && !$changed->{$_} } @$new_ids;
  my %kept = map { $_ => 1 } _longest_increasing([map { $old_idx{$_} } @stay], \@stay);

  my @removed = grep { !$new_set{$_} } @$old_ids;
  my @added;
  for my $i (0 .. $#$new_ids) {
    my $id = $new_ids->[$i];
    next if $kept{$id};
    # a changed id is reported in removed even if it is new to the results,
    # as the RFC's "all Foos in the current results" reads
    push @removed, $id if exists $old_idx{$id} or $changed->{$id};
    push @added, { id => "$id", index => $i };
  }

  return (\@removed, \@added);
}

# The items of @$items at the positions of a longest strictly increasing
# subsequence of @$keys (patience sorting, O(n log n)).
sub _longest_increasing {
  my ($keys, $items) = @_;
  my (@tails, @prev);   # @tails: position of the smallest tail of each length
  for my $i (0 .. $#$keys) {
    my ($lo, $hi) = (0, scalar @tails);
    while ($lo < $hi) {
      my $mid = int(($lo + $hi) / 2);
      if ($keys->[$tails[$mid]] < $keys->[$i]) { $lo = $mid + 1 } else { $hi = $mid }
    }
    $prev[$i] = $lo ? $tails[$lo - 1] : undef;
    $tails[$lo] = $i;
  }
  my @out;
  for (my $i = @tails ? $tails[-1] : undef; defined $i; $i = $prev[$i]) {
    unshift @out, $items->[$i];
  }
  return @out;
}

1;
