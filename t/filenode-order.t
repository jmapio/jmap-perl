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

done_testing;
