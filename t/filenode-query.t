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
is_deeply($s->([ { property => 'tree' } ]), [qw(R b D a)], 'tree: depth-first, siblings by name only (Banana before Docs)');
is_deeply($s->([ { property => 'tree', isAscending => JSON::false } ]), [qw(R D a b)], 'tree descending reverses siblings');
is_deeply($s->([ { property => 'type' } ]), [qw(D R b a)], 'type: directories first, then media type');
is_deeply($s->([ { property => 'type', isAscending => JSON::false } ]), [qw(D R a b)], 'type descending keeps directories first');

# tree over a filtered set keeps the hierarchy of the filtered-out parents
{
  my @t = (
    { id => 'h', parentId => undef, nodeType => 'directory', name => 'home' },
    { id => 'z', parentId => 'h', nodeType => 'directory', name => 'zdir' },
    { id => 'fa', parentId => 'z', nodeType => 'file', name => 'a' },
    { id => 'fc', parentId => 'z', nodeType => 'file', name => 'c' },
    { id => 'fb', parentId => 'h', nodeType => 'file', name => 'b' },
  );
  my %tb = map { $_->{id} => $_ } @t;
  my @files = grep { $_->{nodeType} eq 'file' } @t;
  is_deeply([ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@files, [ { property => 'tree' } ], \%tb) } ],
            [qw(fb fa fc)], 'tree over files only: b (home/b) sorts before zdir/{a,c}');
  # a parentId cycle (bogus server) never drops an id
  my @cyc = ({ id => 'x', parentId => 'y', nodeType => 'file', name => 'x' }, { id => 'y', parentId => 'x', nodeType => 'file', name => 'y' }, $t[0]);
  my %cb = map { $_->{id} => $_ } @cyc;
  is_deeply([ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@cyc, [ { property => 'tree' } ], \%cb) } ],
            [qw(h x y)], 'tree keeps nodes in a parentId cycle');
}

# AND / OR, role, type, modified and accessed dates, text with glob metacharacters
is_deeply($q->({ operator => 'AND', conditions => [ { nodeType => 'file' }, { minSize => 100 } ] }), ['b'], 'AND');
is_deeply($q->({ operator => 'OR', conditions => [ { name => 'Docs' }, { role => 'home' } ] }), [qw(R D)], 'OR with role');
is_deeply($q->({ type => 'image/png' }), ['b'], 'type exact');
is_deeply($q->({ modifiedAfter => '2026-03-02T00:00:00Z' }), [qw(a b)], 'modifiedAfter inclusive');
is_deeply($q->({ modifiedBefore => '2026-03-02T00:00:00Z' }), [qw(R D)], 'modifiedBefore exclusive');
is_deeply($q->({ accessedAfter => '2026-03-03T00:00:00Z' }), [qw(a b)], 'accessedAfter');
is_deeply($q->({ accessedBefore => '2026-03-03T00:00:00Z' }), [qw(R D)], 'accessedBefore');
is_deeply($q->({ createdBefore => '2026-03-01T00:00:00.5Z' }), [qw(R D a)], 'fractional seconds count');
is_deeply($q->({ text => '*.t' }), ['a'], 'text: glob metacharacters');
is_deeply($q->({ text => 'image/' }), ['b'], 'text matches type');
is_deeply($q->({ nameMatch => 'apple.tx' }), [], 'nameMatch is anchored: apple.tx does not match apple.TXT');
is_deeply($q->({ nameMatch => 'apple.tx[t]' }), ['a'], 'a bracket set matches case-insensitively');
ok(!JMAP::FileNode::filter_match({ name => "foo\n", id => 'n' }, { nameMatch => 'foo' }, {}), 'nameMatch: foo does not match "foo\n"');

# depth widens parentId and isTopLevel through a top-level AND only
{
  my $dctx = { byid => \%byid, depth => 1 };
  my $dq = sub { my $f = shift; [ map { $_->{id} } grep { JMAP::FileNode::filter_match($_, $f, $dctx) } @o ] };
  is_deeply($dq->({ parentId => 'R' }), [qw(D a b)], 'depth 1 widens parentId');
  is_deeply($dq->({ operator => 'AND', conditions => [ { parentId => 'R' }, { nodeType => 'file' } ] }), [qw(a b)], 'and through AND');
  is_deeply($dq->({ operator => 'OR', conditions => [ { parentId => 'R' } ] }), [qw(D b)], 'but not through OR');
  is_deeply($dq->({ isTopLevel => JSON::true }), [qw(R D b)], 'depth widens isTopLevel');
  is_deeply($dq->({ ancestorId => 'R' }), [qw(D a b)], 'ancestorId is not narrowed');
}

# filter value types
ok(JMAP::FileNode::filter_problem({ isTopLevel => 'false' }), 'isTopLevel must be a boolean');
ok(JMAP::FileNode::filter_problem({ minSize => '5' }), 'minSize must be a number');
ok(JMAP::FileNode::filter_problem({ minSize => -1 }), 'minSize must be unsigned');
ok(JMAP::FileNode::filter_problem({ createdAfter => 'yesterday' }), 'dates must be UTCDate');
ok(JMAP::FileNode::filter_problem({ operator => 'NOT', conditions => [ { name => 5 } ] }), 'checked inside operators');
ok(!JMAP::FileNode::filter_problem(decode_json('{"isTopLevel":false,"minSize":3,"createdAfter":"2026-01-01T00:00:00.5Z","name":"x"}')), 'valid types pass');

done_testing;
