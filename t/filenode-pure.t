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

my $re = JMAP::FileNode::glob_regex('*.TXT');
ok('notes.txt' =~ $re, 'glob is case-insensitive');
ok('notes.txt.bak' !~ $re, 'glob is anchored');
ok('a1' =~ JMAP::FileNode::glob_regex('a?'), '?');
ok('b' =~ JMAP::FileNode::glob_regex('[abc]'), 'set');
ok('d' =~ JMAP::FileNode::glob_regex('[!abc]'), 'negated set (!)');
ok('d' =~ JMAP::FileNode::glob_regex('[^abc]'), 'negated set (^)');
ok('q' =~ JMAP::FileNode::glob_regex('[a-z]'), 'range');
ok('a.b' =~ JMAP::FileNode::glob_regex('a.b') && 'axb' !~ JMAP::FileNode::glob_regex('a.b'), 'dot is literal');

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

done_testing;
