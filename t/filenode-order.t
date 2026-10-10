#!/usr/bin/perl
# t/filenode-order.t -- FileNode/set ordering and onExists "rename" names.
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::FileNode;

my $oc = \&JMAP::FileNode::order_creates;
my $ord = $oc->({ c => { parentId => '#b' }, b => { parentId => '#a' }, a => { parentId => 'Lroot' } });
is_deeply($ord, [qw(a b c)], 'creates ordered by #parent references');
$ord = $oc->({ x => { parentId => '#y' }, y => { parentId => '#x' }, z => { parentId => 'Lr' } });
is($ord->[0], 'z', 'a cycle among #refs goes last');
is(scalar @$ord, 3, 'and is still listed');
$ord = $oc->({ a => { parentId => '#nosuch' }, b => { parentId => undef } });
is_deeply($ord, [qw(a b)], 'a #ref to an unknown creation id does not hold a create back');
$ord = $oc->({ s => { parentId => '#s' } });
is_deeply($ord, ['s'], 'a self reference is listed once');

my $un = \&JMAP::FileNode::unique_name;
is($un->('a.txt', { 'a.txt' => 1 }), 'a[2].txt', 'first rename');
is($un->('a.txt', { 'a.txt' => 1, 'a[2].txt' => 1 }), 'a[3].txt', 'skips taken');
is($un->('.profile', { '.profile' => 1 }), '.profile[2]', 'leading dot is not an extension');
is($un->('README', { 'README' => 1 }), 'README[2]', 'no extension');
is($un->('x.tar.gz', { 'x.tar.gz' => 1 }), 'x.tar[2].gz', 'only the last extension');
is($un->('A.TXT', { 'a.txt' => 1, 'a[2].txt' => 1 }, 1), 'A[3].TXT', 'case-insensitive: taken keys are lower case');

my $om = \&JMAP::FileNode::order_moves;
# swap a and b
my $steps = $om->({ A => "p\0b", B => "p\0a" }, { "p\0a" => 'A', "p\0b" => 'B' });
is(scalar @$steps, 3, 'a swap takes three steps');
ok(defined $steps->[0][1] && $steps->[0][1] =~ /^\.~tmp~/, 'the first step parks one node under a temporary name');
my $parked = $steps->[0][0];
my ($other) = grep { $_ ne $parked } qw(A B);
is_deeply([ map { [ $_->[0], $_->[1] ] } @$steps[1, 2] ], [ [ $other, undef ], [ $parked, undef ] ],
  'then the other node moves, then the parked one moves to its real destination');
# a chain: c -> where b is, b -> where a is
$steps = $om->({ B => "p\0a", C => "p\0b" }, { "p\0a" => 'A', "p\0b" => 'B', "p\0c" => 'C' });
is_deeply([ map { $_->[0] } @$steps ], [ 'B', 'C' ], 'B vacates b before C takes it');
# (A is not moving, so B's own clash with A is not order_moves' business: update_filenodes
# resolves clashes with non-moving nodes through onExists before ordering.)

# a rotation of three, plus an independent move
$steps = $om->({ A => "p\0b", B => "p\0c", C => "p\0a", D => "q\0d" },
               { "p\0a" => 'A', "p\0b" => 'B', "p\0c" => 'C', "p\0d" => 'D' });
is(scalar @$steps, 5, 'a rotation of three takes four steps, plus the free move');
my %at = %{{ "p\0a" => 'A', "p\0b" => 'B', "p\0c" => 'C', "p\0d" => 'D' }};
my %dest = (A => "p\0b", B => "p\0c", C => "p\0a", D => "q\0d");
my $ok = 1;
for my $s (@$steps) {
  my ($id, $tmp) = @$s;
  my $to = defined $tmp ? "p\0$tmp" : $dest{$id};
  $ok = 0 if defined $at{$to} && $at{$to} ne $id;
  delete $at{$_} for grep { $at{$_} eq $id } keys %at;
  $at{$to} = $id;
}
ok($ok, 'no step lands on an occupied name');
is_deeply(\%at, { "p\0a" => 'C', "p\0b" => 'A', "p\0c" => 'B', "q\0d" => 'D' }, 'and every node ends where it was sent');

# tree order: B lives in A; A moves into B while B moves up to the root
$steps = $om->({ A => "B\0A", B => "R\0B" }, { "R\0A" => 'A', "A\0B" => 'B' }, { A => 'R', B => 'A' });
is_deeply([ map { $_->[0] } @$steps ], [ 'B', 'A' ], 'a node leaves a directory before that directory moves under it');

# the parking spot is checked against what is already there
$steps = $om->({ A => "p\0b", B => "p\0a" }, { "p\0a" => 'A', "p\0b" => 'B', "p\0.~tmp~A" => 'X', "p\0.~tmp~B" => 'Y' });
ok(defined $steps->[0][1] && $steps->[0][1] ne ".~tmp~$steps->[0][0]", 'a taken temporary name is not reused')
  or diag explain $steps;
like($steps->[0][1], qr/^\.~tmp~[AB]\[2\]\z/, 'a free variant of it is');

# $after: a move waits for the nodes it must follow
$steps = $om->({ A => "q\0a", B => "r\0b" }, { "p\0a" => 'A', "s\0b" => 'B' }, undef, { A => ['B'] });
is_deeply([ map { $_->[0] } @$steps ], [ 'B', 'A' ], 'A waits for B');

# $park_in: a node parked outside its directory has left it, for $after
$steps = $om->({ F => "D\0s2", K => "D\0f.txt" }, { "D\0f.txt" => 'F', "D\0s2" => 'S', "S\0k.txt" => 'K' },
               { F => 'D', K => 'S', S => 'D' }, { F => ['K'] }, { K => 'D' });
is_deeply($steps, [ [ 'K', '.~tmp~K', 'D' ], [ 'F', undef ], [ 'K', undef ] ], 'parked in D, then F, then K')
  or diag explain $steps;

# $after waits on each other (two replaces, each of the other's directory):
# the waited-on nodes are parked outside, then all moves complete
$steps = $om->({ A => "P\0h1", B => "P\0h2" }, { "P\0h1" => 'H1', "P\0h2" => 'H2', "H1\0b" => 'B', "H2\0a" => 'A' },
               { A => 'H2', B => 'H1', H1 => 'P', H2 => 'P' }, { A => ['B'], B => ['A'] }, { A => 'P', B => 'P' });
is_deeply([ map { [ $_->[0], defined $_->[1] ? 'tmp' : undef, $_->[2] ] } @$steps ],
          [ [ 'A', 'tmp', 'P' ], [ 'B', 'tmp', 'P' ], [ 'A', undef, undef ], [ 'B', undef, undef ] ],
          'both parked outside their doomed directories, then moved on') or diag explain $steps;

done_testing;
