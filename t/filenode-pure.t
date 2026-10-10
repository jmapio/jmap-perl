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

done_testing;
