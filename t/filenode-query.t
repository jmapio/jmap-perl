#!/usr/bin/perl
# t/filenode-query.t
use strict;
use warnings;
use Test::More;
use JSON;
use lib '.';
use JMAP::FileNode;

my @o = (
  { id => 'R', parentId => undef, nodeType => 'directory', name => 'home', role => 'home', size => undef, type => undef, created => '2026-01-01T00:00:00Z', modified => '2026-01-01T00:00:00Z', accessed => '2026-01-01T00:00:00Z', executable => JSON::false, blobId => undef },
  { id => 'D', parentId => 'R', nodeType => 'directory', name => 'Docs', role => undef, size => undef, type => undef, created => '2026-02-01T00:00:00Z', modified => '2026-02-01T00:00:00Z', accessed => '2026-02-01T00:00:00Z', executable => JSON::false, blobId => undef },
  { id => 'a', parentId => 'D', nodeType => 'file', name => 'apple.TXT', role => undef, size => 10, type => 'text/plain', created => '2026-03-01T00:00:00Z', modified => '2026-03-02T00:00:00Z', accessed => '2026-03-03T00:00:00Z', executable => JSON::true, blobId => 'd-a-1' },
  { id => 'b', parentId => 'R', nodeType => 'file', name => 'Banana.png', role => undef, size => 200, type => 'image/png', created => '2026-04-01T00:00:00Z', modified => '2026-04-01T00:00:00Z', accessed => '2026-04-01T00:00:00Z', executable => JSON::false, blobId => 'd-b-1' },
);
my %byid = map { $_->{id} => $_ } @o;
my $ctx = { byid => \%byid };
my $q = sub { my $f = shift; [ map { $_->{id} } grep { JMAP::FileNode::filter_match($_, $f, $ctx) } @o ] };

is_deeply($q->({ isTopLevel => JSON::true }), ['R'], 'isTopLevel');
is_deeply($q->({ parentId => 'D' }), ['a'], 'parentId');
is_deeply($q->({ ancestorId => 'R' }), [qw(D a b)], 'ancestorId');
is_deeply($q->({ descendantId => 'a' }), [qw(R D)], 'descendantId');
is_deeply($q->({ nodeType => 'file' }), [qw(a b)], 'nodeType');
is_deeply($q->({ hasAnyRole => JSON::true }), ['R'], 'hasAnyRole');
is_deeply($q->({ isExecutable => JSON::true }), ['a'], 'isExecutable');
is_deeply($q->({ minSize => 10, maxSize => 200 }), ['a'], 'minSize inclusive, maxSize exclusive');
is_deeply($q->({ createdBefore => '2026-03-01T00:00:00Z' }), [qw(R D)], 'Before is exclusive');
is_deeply($q->({ createdAfter => '2026-03-01T00:00:00Z' }), [qw(a b)], 'After is inclusive');
is_deeply($q->({ name => 'apple.TXT' }), ['a'], 'name: exact octets');
is_deeply($q->({ name => 'apple.txt' }), [], 'name is case-sensitive');
is_deeply($q->({ nameMatch => '*.txt' }), ['a'], 'nameMatch is case-insensitive');
is_deeply($q->({ typeMatch => 'image/*' }), ['b'], 'typeMatch');
is_deeply($q->({ text => 'banana' }), ['b'], 'text = nameMatch or typeMatch (substring)');
is_deeply($q->({ blobId => 'd-a-1' }), ['a'], 'blobId');
is_deeply($q->({ operator => 'NOT', conditions => [ { nodeType => 'directory' } ] }), [qw(a b)], 'NOT');

my $s = sub { [ map { $_->{id} } @{ JMAP::FileNode::sort_nodes([@o], shift, \%byid) } ] };
is_deeply($s->([ { property => 'name' } ]), [qw(a b D R)], 'name sort is case-insensitive by default');
is_deeply($s->([ { property => 'name', collation => 'i;octet' } ]), [qw(b D a R)], 'i;octet: raw byte order, "Banana.png" "Docs" "apple.TXT" "home"');
is_deeply($s->([ { property => 'nodeType' } ]), [qw(D R a b)], 'directories first');
is_deeply($s->([ { property => 'size', isAscending => JSON::false } ]), [qw(b a D R)], 'size descending, null last then id');
is_deeply($s->([ { property => 'tree' } ]), [qw(R D a b)], 'tree: depth-first, directories first, then by name');

done_testing;
