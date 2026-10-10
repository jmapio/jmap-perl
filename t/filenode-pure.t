#!/usr/bin/perl
# t/filenode-pure.t
use strict;
use warnings;
use utf8;
use Test::More;
use JSON;
use Digest::SHA;
use lib '.';
use JMAP::FileNode;

like(JMAP::FileNode::local_id(), qr/^L[0-9a-f]{32}$/, 'local ids are L + 32 hex');
isnt(JMAP::FileNode::local_id(), JMAP::FileNode::local_id(), 'and unique');
is(JMAP::FileNode::server_id('00001234ocabc'), 'S' . substr(Digest::SHA::sha1_hex('00001234ocabc'), 0, 32), 'server ids are S + hash');

my $b = JMAP::FileNode::blob_id('Labc', '"etag-1"');
like($b, qr/^d-Labc-[0-9a-f]{16}$/, 'blob id shape');
isnt($b, JMAP::FileNode::blob_id('Labc', '"etag-2"'), 'a new etag is a new blob');
is_deeply([ JMAP::FileNode::parse_blob_id($b) ], [ 'Labc', substr($b, -16) ], 'parse');
is_deeply([ JMAP::FileNode::parse_blob_id('f-12') ], [], 'other blob kinds are not ours');
is_deeply([ JMAP::FileNode::parse_blob_id($b . "\n") ], [], 'trailing newline is rejected');

my $np = \&JMAP::FileNode::name_problem;
ok(!$np->('report.pdf'), 'plain name');
ok(!$np->('café [2].txt'), 'unicode, spaces and brackets are fine');
ok($np->(''), 'empty');
ok($np->('a/b'), 'slash');
ok($np->('.'), 'dot');
ok($np->('..'), 'dotdot');
ok($np->("a\x{0}b"), 'control character');
ok($np->('é' x 128), 'over 255 UTF-8 octets');
ok(!$np->('é' x 127), '254 octets is fine');
ok(!$np->('a' x 255), 'exactly 255 UTF-8 octets is fine');
ok($np->('a' x 256), '256 octets is rejected');

my $re = JMAP::FileNode::glob_regex('*.TXT');
ok('notes.txt' =~ $re, 'glob is case-insensitive');
ok('notes.txt.bak' !~ $re, 'glob is anchored');
ok('a1' =~ JMAP::FileNode::glob_regex('a?'), '?');
ok('b' =~ JMAP::FileNode::glob_regex('[abc]'), 'set');
ok('d' =~ JMAP::FileNode::glob_regex('[!abc]'), 'negated set (!)');
ok('d' =~ JMAP::FileNode::glob_regex('[^abc]'), 'negated set (^)');
ok('q' =~ JMAP::FileNode::glob_regex('[a-z]'), 'range');
ok('a.b' =~ JMAP::FileNode::glob_regex('a.b') && 'axb' !~ JMAP::FileNode::glob_regex('a.b'), 'dot is literal');

# Client-supplied globs must never die.
my $rev;
my $ok = eval { $rev = JMAP::FileNode::glob_regex('[z-a]'); 1 };
ok($ok, 'reversed range does not die') or diag $@;
ok('[z-a]' =~ $rev, 'reversed range matches the literal text "[z-a]"');
ok('m' !~ $rev, 'reversed range matches no character class');
$ok = eval { $rev = JMAP::FileNode::glob_regex('a[b'); 1 };
ok($ok, 'unterminated [ does not die') or diag $@;
ok('a[b' =~ $rev, 'unterminated [ is literal (a[b)');
ok('ab' !~ $rev, 'unterminated [ is not a class');
$ok = eval { $rev = JMAP::FileNode::glob_regex('['); 1 };
ok($ok && '[' =~ $rev, 'lone [ is literal');
$ok = eval { $rev = JMAP::FileNode::glob_regex('[]a]'); 1 };
ok($ok, 'set starting with ] does not die') or diag $@;
ok('[]a]' =~ $rev, 'set starting with ] is treated literally');
$ok = eval { $rev = JMAP::FileNode::glob_regex('[a\\b]'); 1 };
ok($ok, 'set containing backslash does not die') or diag $@;
ok('a' =~ $rev && '\\' =~ $rev, 'backslash in a set is a member');
$ok = eval { $rev = JMAP::FileNode::glob_regex('[a-]'); 1 };
ok($ok, 'set with trailing - does not die') or diag $@;
ok('-' =~ $rev && 'a' =~ $rev, 'trailing - in a set is a literal member');
$ok = eval { $rev = JMAP::FileNode::glob_regex('[-a]'); 1 };
ok($ok && '-' =~ $rev, 'leading - in a set is a literal member');

my $r = JMAP::FileNode::rights([qw(read write-content bind write-acl)], [qw(unbind bind)]);
ok($r->{mayRead} && $r->{mayModifyContent} && $r->{mayAddChildren} && $r->{mayShare}, 'mapped rights');
ok($r->{mayDelete} && $r->{mayRename}, 'delete and rename need unbind on the parent');
ok(!JMAP::FileNode::rights([qw(read)], [qw(read)])->{mayDelete}, 'no unbind, no delete');
ok(JMAP::FileNode::rights(undef, undef)->{mayShare}, 'no privilege set reported: all rights');
ok(JMAP::FileNode::rights([qw(all)], [])->{mayModifyContent}, 'DAV:all implies everything');
ok(JMAP::FileNode::rights([qw(write)], [qw(write)])->{mayDelete}, 'DAV:write includes bind/unbind/write-content');

is(JMAP::FileNode::utc(0), '1970-01-01T00:00:00Z', 'utc');
is(JMAP::FileNode::epoch('2026-10-10T01:45:31Z'), 1791596731, 'epoch');
is(JMAP::FileNode::epoch('nonsense'), undef, 'bad date');

# epoch() must return exactly one value, even when timegm dies.
my @x = (JMAP::FileNode::epoch('2026-13-01T00:00:00Z'), 5);
is(scalar @x, 2, 'epoch of an invalid date returns one value, not an empty list');
is($x[1], 5, 'following hash/list values are not shifted');
my %h = (created => JMAP::FileNode::epoch('2026-13-01T00:00:00Z'), name => 'x');
is_deeply(\%h, { created => undef, name => 'x' }, 'epoch inside a hash constructor');

is(JMAP::FileNode::epoch(JMAP::FileNode::utc(1234567890)), 1234567890, 'epoch(utc(t)) round-trips');
is(JMAP::FileNode::utc(JMAP::FileNode::epoch('2009-02-13T23:31:30Z')), '2009-02-13T23:31:30Z', 'utc(epoch(s)) round-trips');

# R7: empty privileges inherit from the nearest ancestor that reports some
{
  my %n = (
    home => { nodeid => 'h', privs => 'read write-content bind unbind' },
    ro   => { nodeid => 'r', privs => 'read', parentid => 'h' },
    f1   => { nodeid => 'f1', privs => '', parentid => 'h' },
    f2   => { nodeid => 'f2', privs => '', parentid => 'r' },
    f3   => { nodeid => 'f3', privs => undef },
  );
  my %by = map { $_->{nodeid} => $_ } values %n;
  my $up = sub { defined $_[0]{parentid} ? $by{ $_[0]{parentid} } : undef };
  my $eff = sub { JMAP::FileNode::effective_privs($n{$_[0]}, $up) };
  ok(JMAP::FileNode::rights($eff->('f1'), $eff->('home'))->{mayModifyContent}, 'empty file privs + parent with write-content: mayModifyContent');
  ok(!JMAP::FileNode::rights($eff->('f2'), $eff->('ro'))->{mayModifyContent}, 'parent without write-content: not');
  ok(!defined $eff->('f3'), 'no privs anywhere: undef');
  ok(JMAP::FileNode::rights($eff->('f3'), undef)->{mayModifyContent}, 'and then all rights');
  is_deeply($eff->('ro'), ['read'], 'a non-empty set is authoritative');
}

# --- sharing (Task 10)
{
  my $CY = '{http://cyrusimap.org/ns/}';
  # Cyrus's DAV:supported-privilege-set, as WebDAVTalk::parse_privilege_tree reads it
  my %tree = (all => { parent => undef, abstract => 0 }, read => { parent => 'all', abstract => 0 },
              write => { parent => 'all', abstract => 0 }, bind => { parent => 'write', abstract => 0 },
              'write-content' => { parent => 'bind', abstract => 0 }, unbind => { parent => 'write', abstract => 0 },
              "${CY}admin" => { parent => 'all', abstract => 0 },
              'write-acl' => { parent => "${CY}admin", abstract => 1 }, 'read-acl' => { parent => "${CY}admin", abstract => 1 });
  my $t = JSON::true; my $f = JSON::false;
  is_deeply(JMAP::FileNode::share_rights([ 'read', "${CY}admin" ], \%tree),
            { mayRead => $t, mayAddChildren => $f, mayRename => $f, mayDelete => $f, mayModifyContent => $f, mayShare => $t },
            'the server\'s admin privilege holds write-acl: mayShare');
  ok(JMAP::FileNode::share_rights(['bind'], \%tree)->{mayModifyContent}, 'Cyrus: bind holds write-content');
  ok(!JMAP::FileNode::share_rights(['bind'], undef)->{mayModifyContent}, 'without a tree, bind is only bind');
  ok(JMAP::FileNode::rights([ "${CY}admin" ], undef, \%tree)->{mayShare}, 'myRights use the tree too');

  is_deeply(JMAP::FileNode::grant_for_rights({ mayRead => $t, mayShare => $t }, \%tree), [ 'read', "${CY}admin" ],
            'write-acl is abstract: its nearest grantable aggregate is granted');
  is_deeply(JMAP::FileNode::grant_for_rights({ mayRead => $t, mayAddChildren => $t, mayModifyContent => $t }, \%tree),
            [ qw(bind read) ], 'write-content is left out where bind holds it');
  is_deeply(JMAP::FileNode::grant_for_rights({ mayRename => $t, mayDelete => $f }, \%tree), ['unbind'], 'rename and delete are unbind');
  is_deeply(JMAP::FileNode::grant_for_rights({ mayRead => $t, mayShare => $t }, undef), [ qw(read write-acl) ], 'no tree: the plain names');
  is_deeply(JMAP::FileNode::grant_for_rights({ mayRead => $f }, \%tree), [], 'no rights, no privileges');
  my %notree = (read => { parent => undef, abstract => 0 });
  is_deeply([ JMAP::FileNode::grant_for_rights({ mayShare => $t }, \%notree) ], [ undef, 'mayShare' ],
            'a right the server has no privilege for');
  my %abs = (read => { parent => undef, abstract => 0 }, 'write-acl' => { parent => undef, abstract => 1 });
  is_deeply([ JMAP::FileNode::grant_for_rights({ mayShare => $t }, \%abs) ], [ undef, 'mayShare' ],
            'abstract with nothing grantable above it');

  my $base = '/dav/principals/user/';
  is(JMAP::FileNode::share_user('/dav/principals/user/user2/', $base), 'user2', 'principal -> user id');
  is(JMAP::FileNode::share_user('/dav/principals/user/jane.doe@example.com/', $base), 'jane.doe@example.com', 'with a domain');
  is(JMAP::FileNode::share_user('/dav/principals/group/staff/', $base), undef, 'a group is not a user');
  is(JMAP::FileNode::share_user('/dav/principals/user/a/b/', $base), undef, 'not directly below the base');
  is(JMAP::FileNode::share_user(qq{/dav/principals/user/a"b<c/}, $base), undef, 'not a safe id');
  is(JMAP::FileNode::share_user('self', $base), undef, 'self is no user');
  is(JMAP::FileNode::share_user('/principals/users/bob/', undef), undef, 'no base known: nobody is a user');
  is(JMAP::FileNode::share_user('/dav/principals/staff/', '/dav/principals/user/'), undef, 'a group beside the users is not one');

  # propagation to descendants: the delta, and splicing it into another ACL
  my $d = JMAP::FileNode::share_delta({ a => { mayRead => $t }, b => { mayRead => $t }, c => { mayRead => $t } },
                                      { a => { mayRead => $t }, b => { mayRead => $t, mayShare => $t }, n => { mayRead => $t } });
  is_deeply([ sort keys %$d ], [ qw(b c n) ], 'delta: changed, removed and added users only');
  is($d->{c}, undef, 'a removed user is undef');
  ok($d->{b}{mayShare}, 'a changed one has its new rights');
  is_deeply(JMAP::FileNode::share_delta(undef, {}), {}, 'nothing to nothing: no delta');
  my @desc = (
    { principal => 'self', grant => ['all'], deny => [] },
    { principal => "${base}b/", href => "${base}b/", grant => ['read'], deny => [] },
    { principal => "${base}c/", grant => ['read', 'bind'], deny => [] },
    { principal => "${base}z/", grant => ['read'], deny => [] },          # not in the delta: untouched
    { principal => "${base}c/", grant => [], deny => ['write'] },        # a deny: not sharing, kept
  );
  my $out = JMAP::FileNode::splice_share(\@desc, $d, base => $base, tree => \%tree);
  is_deeply([ map { $_->{principal} . ':' . join(',', @{ $_->{grant} }, map { "-$_" } @{ $_->{deny} }) } @$out ],
            [ 'self:all', "${base}z/:read", "${base}c/:-write", "${base}b/:read,${CY}admin", "${base}n/:read" ],
            'only the delta\'s users change; everything else stays') or diag explain $out;

  is(JMAP::FileNode::sharewith_problem(undef), undef, 'null is fine');
  is(JMAP::FileNode::sharewith_problem({}), undef, 'so is {}');
  is(JMAP::FileNode::sharewith_problem({ user2 => { mayRead => $t } }), undef, 'a right left out is false');
  ok(JMAP::FileNode::sharewith_problem($_), 'bad: ' . JSON->new->allow_nonref->canonical->encode($_))
    for 'x', [], { user2 => 1 }, { user2 => { mayRead => 1 } }, { user2 => { mayFly => $t } },
        { 'a/b' => { mayRead => $t } }, { qq{a"b<c} => { mayRead => $t } }, { '..' => {} }, { '' => {} };

  is(JMAP::FileNode::sharewith_json({ b => { mayRead => $t }, a => { mayShare => $f } }),
     '{"b":{"mayAddChildren":false,"mayDelete":false,"mayModifyContent":false,"mayRead":true,"mayRename":false,"mayShare":false}}',
     'canonical, every right present, users without rights left out');
  is(JMAP::FileNode::sharewith_json({ a => {} }), undef, 'nobody left: undef');

  my @aces = (
    { principal => 'self', grant => ['all'], deny => [] },
    { principal => '/dav/principals/user/u/', grant => ['all'], deny => [] },                 # the owner
    { principal => '/dav/principals/user/admin/', grant => ['all'], deny => [] },             # not a principal (hidden)
    { principal => '/dav/principals/user/user2/', grant => ['read'], deny => [] },
    { principal => '/dav/principals/user/user2/', grant => ['bind'], deny => [] },            # merged
    { principal => '/dav/principals/user/user3/', grant => [], deny => ['read'] },            # a deny: kept
    { principal => '/dav/principals/user/user4/', grant => ['read'], deny => [], inherited => 1 },
    { principal => '/dav/principals/user/user5/', grant => ['read'], deny => [], protected => 1 },
    { principal => '/dav/principals/group/g/', grant => ['read'], deny => [] },
  );
  my ($share, $kept) = JMAP::FileNode::share_aces(\@aces, base => $base, owner => '/dav/principals/user/u/', tree => \%tree,
                                                  hidden => sub { $_[0] =~ m{/admin/} });
  is_deeply($share, { user2 => { mayRead => $t, mayAddChildren => $t, mayRename => $f, mayDelete => $f, mayModifyContent => $t, mayShare => $f } },
            'only user2 is shared with; its ACEs are merged') or diag explain $share;
  is_deeply([ map { $_->{principal} } @$kept ],
            [ 'self', map { "/dav/principals/$_/" } qw(user/u user/admin user/user3 user/user4 user/user5 group/g) ],
            'everything else is kept as it is');
  ($share) = JMAP::FileNode::share_aces(\@aces, base => $base, me => 'user2');
  ok($share && !exists $share->{user2} && $share->{admin}, 'the account\'s own user is never in shareWith (nor hidden here: admin)');
}

# reconcile: a changed ACL on a directory is an update
{
  my $row = { nodeid => 'Lx', href => '/r/d', nodetype => 'directory', etag => 'e', sharewith => undef, privs => undef, deadprops => undef };
  my $e = { href => '/r/d', isCollection => 1, etag => 'e', dead => {} };
  is(scalar @{ JMAP::FileNode::reconcile([$row], [ { %$e } ])->{update} }, 0, 'no ACL asked for: no update');
  is(scalar @{ JMAP::FileNode::reconcile([$row], [ { %$e, sharewith => undef } ])->{update} }, 0, 'nobody before or after');
  is(scalar @{ JMAP::FileNode::reconcile([$row], [ { %$e, sharewith => '{"u":{}}' } ])->{update} }, 1, 'shared now: an update');
}

# the in-memory cap on one file's content (JMAP_FILES_MAX_BYTES)
{
  local $ENV{JMAP_FILES_MAX_BYTES};
  delete $ENV{JMAP_FILES_MAX_BYTES};
  is(JMAP::FileNode::max_bytes(), 256 * 1024 * 1024, 'default 256 MiB');
  $ENV{JMAP_FILES_MAX_BYTES} = '1048576';
  is(JMAP::FileNode::max_bytes(), 1048576, 'from the environment');
  $ENV{JMAP_FILES_MAX_BYTES} = 'lots';
  is(JMAP::FileNode::max_bytes(), 256 * 1024 * 1024, 'a value that is no number: the default');
  $ENV{JMAP_FILES_MAX_BYTES} = '0';
  is(JMAP::FileNode::max_bytes(), 256 * 1024 * 1024, 'zero: the default');
  $ENV{JMAP_FILES_MAX_BYTES} = '8';
  my $e = JMAP::FileNode::too_large_error('the file', 9);
  like($e, qr/^fileTooLarge: the file is 9 bytes, over JMAP_FILES_MAX_BYTES \(8\)$/, 'the error names the size and the cap');
  ok(JMAP::FileNode::is_too_large($e), 'and is recognised');
  ok(JMAP::FileNode::is_too_large("$e\n"), 'with a trailing newline too');
  ok(!JMAP::FileNode::is_too_large('HTTP 412'), 'another error is not');
  ok(!JMAP::FileNode::is_too_large(undef), 'nor nothing');
}

done_testing;
