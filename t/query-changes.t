#!/usr/bin/perl
# t/query-changes.t -- JMAP::QueryChanges::diff, the removed/added lists of
# every /queryChanges: applying them to the old results must give the new
# ones (RFC 8620 S5.6), while reporting as few ids as it can.
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::QueryChanges;

# What a client does with the response (RFC 8620 S5.6).
sub apply {
  my ($old, $removed, $added) = @_;
  my %gone = map { $_ => 1 } @$removed;
  my @list = grep { !$gone{$_} } @$old;
  splice @list, $_->{index}, 0, $_->{id} for @$added;
  return \@list;
}

sub check {
  my ($name, $old, $new, $changed, $want_removed, $want_added) = @_;
  my ($removed, $added) = JMAP::QueryChanges::diff($old, $new, $changed);
  is_deeply(apply($old, $removed, $added), $new, "$name: applies to the new results");
  is_deeply([sort @$removed], [sort @$want_removed], "$name: removed") if $want_removed;
  is_deeply([map { $_->{id} } @$added], $want_added, "$name: added") if $want_added;
  is_deeply([map { $_->{index} } @$added], [sort { $a <=> $b } map { $_->{index} } @$added],
            "$name: added is in index order");
}

check('nothing changed', [qw(a b c)], [qw(a b c)], {}, [], []);
check('one removed', [qw(a b c)], [qw(a c)], {}, ['b'], []);
check('one added', [qw(a c)], [qw(a b c)], {}, [], ['b']);
check('an insertion at the top reports only itself', [qw(b c d e)], [qw(a b c d e)], {}, [], ['a']);
check('one moved to the end', [qw(a b c d)], [qw(b c d a)], {}, ['a'], ['a']);
{
  my ($removed, $added) = JMAP::QueryChanges::diff([qw(a b)], [qw(b a)], {});
  is(scalar @$removed, 1, 'a swap reports just one of the pair');
  is_deeply(apply([qw(a b)], $removed, $added), [qw(b a)], '... and applies');
}
check('a changed id is reported even in place', [qw(a b c)], [qw(a b c)], { b => 1 }, ['b'], ['b']);
check('a changed id new to the results', [qw(a)], [qw(a b)], { b => 1 }, ['b'], ['b']);
check('everything removed', [qw(a b)], [], {}, [qw(a b)], []);
check('from nothing', [], [qw(a b)], {}, [], [qw(a b)]);
check('reversed', [qw(a b c d)], [qw(d c b a)], {});

# any old and new lists
srand(8620);
for my $round (1 .. 300) {
  my @pool = map { "id$_" } 1 .. 12;
  my @old = grep { rand() < 0.6 } @pool;
  my @new = grep { rand() < 0.6 } @pool;
  @old = sort { rand() <=> 0.5 } @old;
  @new = sort { rand() <=> 0.5 } @new;
  my %changed = map { $_ => 1 } grep { rand() < 0.2 } @new;
  my ($removed, $added) = JMAP::QueryChanges::diff(\@old, \@new, \%changed);
  is_deeply(apply(\@old, $removed, $added), \@new, "random $round applies")
    or diag explain { old => \@old, new => \@new, changed => \%changed };
}

done_testing;
