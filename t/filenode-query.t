#!/usr/bin/perl
# t/filenode-query.t -- FileNode/query filters and sorts, draft-ietf-jmap-filenode-20
use strict;
use warnings;
use Test::More;
use JSON;
use lib '.';
use JMAP::FileNode;

my @o = (
  # -20 S3.1: each node carries only its own @type's properties
  { id => 'R', parentId => undef, '@type' => 'Directory', name => 'home', role => 'home', created => '2026-01-01T00:00:00Z', modified => '2026-01-01T00:00:00Z', accessed => '2026-01-01T00:00:00Z' },
  { id => 'D', parentId => 'R', '@type' => 'Directory', name => 'Docs', role => undef, created => '2026-02-01T00:00:00Z', modified => '2026-02-01T00:00:00Z', accessed => '2026-02-01T00:00:00Z' },
  { id => 'a', parentId => 'D', '@type' => 'File', name => 'apple.TXT', size => 10, mediaType => 'text/plain', created => '2026-03-01T00:00:00Z', modified => '2026-03-02T00:00:00Z', accessed => '2026-03-03T00:00:00Z', executable => JSON::true, blobId => 'd-a-1' },
  { id => 'b', parentId => 'R', '@type' => 'File', name => 'Banana.png', size => 200, mediaType => 'image/png', created => '2026-04-01T00:00:00Z', modified => '2026-04-01T00:00:00Z', accessed => '2026-04-01T00:00:00Z', executable => JSON::false, blobId => 'd-b-1' },
);
my %byid = map { $_->{id} => $_ } @o;
my $ctx = { byid => \%byid };
my $q = sub { my $f = shift; [ map { $_->{id} } grep { JMAP::FileNode::filter_match($_, $f, $ctx) } @o ] };

is_deeply($q->({ isTopLevel => JSON::true }), ['R'], 'isTopLevel');
is_deeply($q->({ parentId => 'D' }), ['a'], 'parentId');
is_deeply($q->({ ancestorId => 'R' }), [qw(D a b)], 'ancestorId');
is_deeply($q->({ descendantId => 'a' }), [qw(R D)], 'descendantId');
is_deeply($q->({ nodeType => 'File' }), [qw(a b)], 'nodeType: matches @type');
is_deeply($q->({ hasAnyRole => JSON::false }), ['D'], 'hasAnyRole false matches only Directories without a role (-20)');
is_deeply($q->({ isExecutable => JSON::false }), ['b'], 'isExecutable false matches only Files (-20)');
is_deeply($q->({ hasAnyRole => JSON::true }), ['R'], 'hasAnyRole');
is_deeply($q->({ isExecutable => JSON::true }), ['a'], 'isExecutable');
is_deeply($q->({ minSize => 10, maxSize => 200 }), ['a'], 'minSize inclusive, maxSize exclusive');
is_deeply($q->({ createdBefore => '2026-03-01T00:00:00Z' }), [qw(R D)], 'Before is exclusive');
is_deeply($q->({ createdAfter => '2026-03-01T00:00:00Z' }), [qw(a b)], 'After is inclusive');
is_deeply($q->({ name => 'apple.TXT' }), ['a'], 'name: exact octets');
is_deeply($q->({ name => 'apple.txt' }), [], 'name is case-sensitive');
is_deeply($q->({ nameMatch => '*.txt' }), ['a'], 'nameMatch is case-insensitive');
is_deeply($q->({ mediaTypeMatch => 'image/*' }), ['b'], 'mediaTypeMatch');
is_deeply($q->({ text => 'banana' }), ['b'], 'text: a substring of name or mediaType, case-insensitive');
is_deeply($q->({ blobId => 'd-a-1' }), ['a'], 'blobId');
is_deeply($q->({ operator => 'NOT', conditions => [ { nodeType => 'Directory' } ] }), [qw(a b)], 'NOT');

my $s = sub { [ map { $_->{id} } @{ JMAP::FileNode::sort_nodes([@o], shift, \%byid) } ] };
is_deeply($s->([ { property => 'name' } ]), [qw(a b D R)], 'name sort is case-insensitive by default');
is_deeply($s->([ { property => 'name', collation => 'i;octet' } ]), [qw(b D a R)], 'i;octet: raw byte order, "Banana.png" "Docs" "apple.TXT" "home"');
is_deeply($s->([ { property => 'nodeType' } ]), [qw(D R a b)], 'directories first');
is_deeply($s->([ { property => 'size' } ]), [qw(D R a b)], 'size: nodes without it first when ascending (-20), among themselves by id');
is_deeply($s->([ { property => 'size', isAscending => JSON::false } ]), [qw(b a D R)], 'size descending: without it last');
is_deeply($s->([ { property => 'size' }, { property => 'name' } ]), [qw(D R a b)], 'nodes without it are ordered by the next comparator');
is_deeply($s->([ { property => 'tree' } ]), [qw(R b D a)], 'tree: depth-first, siblings by name only (Banana before Docs)');
is_deeply($s->([ { property => 'tree', isAscending => JSON::false } ]), [qw(R D a b)], 'tree descending reverses siblings');
is_deeply($s->([ { property => 'mediaType' } ]), [qw(D R b a)], 'mediaType: Directories (without one) first, then by media type');
is_deeply($s->([ { property => 'mediaType', isAscending => JSON::false } ]), [qw(a b D R)], 'mediaType descending: Directories last (-20)');

# tree over a filtered set keeps the hierarchy of the filtered-out parents
{
  my @t = (
    { id => 'h', parentId => undef, '@type' => 'Directory', name => 'home' },
    { id => 'z', parentId => 'h', '@type' => 'Directory', name => 'zdir' },
    { id => 'fa', parentId => 'z', '@type' => 'File', name => 'a' },
    { id => 'fc', parentId => 'z', '@type' => 'File', name => 'c' },
    { id => 'fb', parentId => 'h', '@type' => 'File', name => 'b' },
  );
  my %tb = map { $_->{id} => $_ } @t;
  my @files = grep { $_->{'@type'} eq 'File' } @t;
  is_deeply([ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@files, [ { property => 'tree' } ], \%tb) } ],
            [qw(fb fa fc)], 'tree over files only: b (home/b) sorts before zdir/{a,c}');
  # a parentId cycle (bogus server) never drops an id
  my @cyc = ({ id => 'x', parentId => 'y', '@type' => 'File', name => 'x' }, { id => 'y', parentId => 'x', '@type' => 'File', name => 'y' }, $t[0]);
  my %cb = map { $_->{id} => $_ } @cyc;
  is_deeply([ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@cyc, [ { property => 'tree' } ], \%cb) } ],
            [qw(h x y)], 'tree keeps nodes in a parentId cycle');
}

# AND / OR, role, type, modified and accessed dates, text with glob metacharacters
is_deeply($q->({ operator => 'AND', conditions => [ { '@type' => 'File' }, { minSize => 100 } ] }), ['b'], 'AND');
is_deeply($q->({ operator => 'OR', conditions => [ { name => 'Docs' }, { role => 'home' } ] }), [qw(R D)], 'OR with role');
is_deeply($q->({ mediaType => 'image/png' }), ['b'], 'mediaType exact');
is_deeply($q->({ modifiedAfter => '2026-03-02T00:00:00Z' }), [qw(a b)], 'modifiedAfter inclusive');
is_deeply($q->({ modifiedBefore => '2026-03-02T00:00:00Z' }), [qw(R D)], 'modifiedBefore exclusive');
is_deeply($q->({ accessedAfter => '2026-03-03T00:00:00Z' }), [qw(a b)], 'accessedAfter');
is_deeply($q->({ accessedBefore => '2026-03-03T00:00:00Z' }), [qw(R D)], 'accessedBefore');
is_deeply($q->({ createdBefore => '2026-03-01T00:00:00.5Z' }), [qw(R D a)], 'fractional seconds count');
is_deeply($q->({ text => '*.t' }), [], 'text is not a glob (-20): "*" is a character like any other');
is_deeply($q->({ text => 'E.T' }), ['a'], 'text: case-insensitive substring');
is_deeply($q->({ text => 'image/' }), ['b'], 'text matches mediaType');
is_deeply($q->({ nameMatch => 'apple.tx' }), [], 'nameMatch is anchored: apple.tx does not match apple.TXT');
is_deeply($q->({ nameMatch => 'apple.tx[t]' }), ['a'], 'a bracket set matches case-insensitively');
ok(!JMAP::FileNode::filter_match({ name => "foo\n", id => 'n' }, { nameMatch => 'foo' }, {}), 'nameMatch: foo does not match "foo\n"');

# -20 S3.2.5 depth: counted from the top level, never from parentId
is(JMAP::FileNode::node_depth('R', \%byid), 0, 'a top-level node is at depth 0');
is(JMAP::FileNode::node_depth('a', \%byid), 2, 'home/Docs/apple.TXT is at depth 2');

# filter value types
ok(JMAP::FileNode::filter_problem({ isTopLevel => 'false' }), 'isTopLevel must be a boolean');
ok(JMAP::FileNode::filter_problem({ minSize => '5' }), 'minSize must be a number');
ok(JMAP::FileNode::filter_problem({ minSize => -1 }), 'minSize must be unsigned');
ok(JMAP::FileNode::filter_problem({ createdAfter => 'yesterday' }), 'dates must be UTCDate');
ok(JMAP::FileNode::filter_problem({ operator => 'NOT', conditions => [ { name => 5 } ] }), 'checked inside operators');
ok(!JMAP::FileNode::filter_problem(decode_json('{"isTopLevel":false,"minSize":3,"createdAfter":"2026-01-01T00:00:00.5Z","name":"x"}')), 'valid types pass');

done_testing;
