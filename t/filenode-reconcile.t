#!/usr/bin/perl
# t/filenode-reconcile.t
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::FileNode;

my $rec = \&JMAP::FileNode::reconcile;
my $R = '/r';
my %dir = (nodetype => 'directory');

sub row   { my %r = @_; return { nodetype => 'file', %r } }
sub entry { my %e = @_; return { isCollection => 0, %e } }

# unchanged
my $m = [ row(nodeid => 'L1', href => "$R/a", etag => 'e1', size => 1, modified => 10) ];
my $l = [ entry(href => "$R/a", etag => 'e1', size => 1, modified => 10) ];
is_deeply($rec->($m, $l, {}), { create => [], update => [], destroy => [] }, 'nothing changed');

# an ACL change elsewhere changes privileges: an update (myRights changes)
my $mp = [ row(nodeid => 'L1', href => "$R/a", etag => 'e1', size => 1, modified => 10, privs => 'read write-content') ];
my $lp = [ entry(href => "$R/a", etag => 'e1', size => 1, modified => 10, privileges => ['read']) ];
is(scalar @{ $rec->($mp, $lp, {})->{update} }, 1, 'privilege change is an update');

# content change in place
$l = [ entry(href => "$R/a", etag => 'e2', size => 2, modified => 11) ];
my $r = $rec->($m, $l, {});
is(scalar @{$r->{update}}, 1, 'changed in place is an update');
is($r->{update}[0][0]{nodeid}, 'L1', 'same node');

# Cyrus: moved by another client, ETag changed, size+mtime unique -> same id
$l = [ entry(href => "$R/sub/moved", etag => 'eX', size => 1, modified => 10) ];
$r = $rec->($m, $l, {});
is_deeply([ map { $_->[0]{nodeid} } @{$r->{update}} ], ['L1'], 'move matched by size + modified');
is($r->{update}[0][1]{href}, "$R/sub/moved", 'with its new href');
is_deeply($r->{create}, [], 'not created');
is_deeply($r->{destroy}, [], 'not destroyed');

# ambiguous size+mtime -> destroy + create, never a guess
$m = [ row(nodeid => 'L1', href => "$R/a", size => 1, modified => 10),
       row(nodeid => 'L2', href => "$R/b", size => 1, modified => 10) ];
$l = [ entry(href => "$R/x", size => 1, modified => 10), entry(href => "$R/y", size => 1, modified => 10) ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 2, 'ambiguous fingerprints: both destroyed');
is(scalar @{$r->{create}}, 2, 'and both created');
like($r->{create}[0]{nodeid}, qr/^L/, 'with local ids');

# etag only counts when the server's etags are proven content hashes
$m = [ row(nodeid => 'L1', href => "$R/a", etag => 'same', size => 1, modified => 10) ];
$l = [ entry(href => "$R/z", etag => 'same', size => 1, modified => 99) ];
is(scalar @{ $rec->($m, $l, {})->{destroy} }, 1, 'etag ignored when not content');
is(scalar @{ $rec->($m, $l, { etagIsContent => 1 })->{update} }, 1, 'etag matched when content');

# sha1 beats everything
$l = [ entry(href => "$R/z", sha1 => 'abc', size => 5, modified => 1) ];
$m = [ row(nodeid => 'L1', href => "$R/a", fingerprint => 'abc', size => 1, modified => 10) ];
is(scalar @{ $rec->($m, $l, {})->{update} }, 1, 'sha1 fingerprint matches');

# server ids: S-prefixed, and a fileid match survives any move
$m = [ row(nodeid => JMAP::FileNode::server_id('f1'), href => "$R/a", fileid => 'f1') ];
$l = [ entry(href => "$R/q/w", fileid => 'f1', size => 7, modified => 70) ];
$r = $rec->($m, $l, {});
is($r->{update}[0][0]{nodeid}, JMAP::FileNode::server_id('f1'), 'fileid match');
$r = $rec->([], [ entry(href => "$R/new", fileid => 'f9') ], {});
is($r->{create}[0]{nodeid}, JMAP::FileNode::server_id('f9'), 'new node with a fileid gets an S id');

# a directory is never matched by fingerprint, and type changes are not "same href"
$m = [ row(nodeid => 'L1', href => "$R/d", %dir) ];
$l = [ entry(href => "$R/d", isCollection => 0, size => 1, modified => 1) ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 1, 'dir replaced by a file of the same name: destroy');
is(scalar @{$r->{create}}, 1, 'and create');

# extra: undef fingerprints never pair; a tier-1 pairing is not re-paired in tier 3
$m = [ row(nodeid => 'L1', href => "$R/a"), row(nodeid => 'L2', href => "$R/b") ];
$l = [ entry(href => "$R/x"), entry(href => "$R/y") ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 2, 'no fingerprint data: nothing paired');
$m = [ row(nodeid => 'L1', href => "$R/a", fingerprint => 'abc', size => 1, modified => 10),
       row(nodeid => 'L2', href => "$R/b", size => 1, modified => 10) ];
$l = [ entry(href => "$R/x", sha1 => 'abc', size => 1, modified => 10) ];
$r = $rec->($m, $l, {});
is_deeply([ map { $_->[0]{nodeid} } @{$r->{update}} ], ['L1'], 'entry paired once, by the strongest tier');
is_deeply([ map { $_->{nodeid} } @{$r->{destroy}} ], ['L2'], 'other row destroyed');

# duplicate fileids are ambiguous, not guessed
$m = [ row(nodeid => 'L1', href => "$R/a", fileid => 'dup') ];
$l = [ entry(href => "$R/x", fileid => 'dup'), entry(href => "$R/y", fileid => 'dup') ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{create}}, 2, 'duplicate fileid entries: both created');

# fileid matching refuses a change of kind
$m = [ row(nodeid => JMAP::FileNode::server_id('k1'), href => "$R/a", fileid => 'k1') ];
$l = [ entry(href => "$R/a", isCollection => 1, fileid => 'k1') ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 1, 'file->dir with same fileid: destroy');
is(scalar @{$r->{create}}, 1, 'and create');
is(scalar @{$r->{update}}, 0, 'not an update');
$m = [ row(nodeid => JMAP::FileNode::server_id('k2'), href => "$R/d", fileid => 'k2', %dir) ];
$l = [ entry(href => "$R/e", fileid => 'k2') ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 1, 'dir->file with same fileid: destroy');
is(scalar @{$r->{create}}, 1, 'and create');

# an S id still held by a mirror row is never reissued in the same pass
my $sid = JMAP::FileNode::server_id('dupf');
$m = [ row(nodeid => $sid, href => "$R/a", fileid => 'dupf'),
       row(nodeid => 'L9', href => "$R/b", fileid => 'dupf') ];
$l = [ entry(href => "$R/c", fileid => 'dupf') ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 2, 'duplicate-fileid rows both destroyed');
like($r->{create}[0]{nodeid}, qr/^L/, 'created with a local id, not the held S id');
isnt($r->{create}[0]{nodeid}, $sid, 'S id not reused');

# the same href listed twice is one node
$l = [ entry(href => "$R/a", size => 1), entry(href => "$R/a", size => 2) ];
$r = $rec->([], $l, {});
is(scalar @{$r->{create}}, 1, 'duplicate href: one node');
is($r->{create}[0]{size}, 1, 'first entry kept');

# a directory moved with a file inside: the file keeps its id, the directory does not
$m = [ row(nodeid => 'LD', href => "$R/d", %dir),
       row(nodeid => 'LF', href => "$R/d/f", size => 3, modified => 30) ];
$l = [ entry(href => "$R/n", isCollection => 1),
       entry(href => "$R/n/f", size => 3, modified => 30) ];
$r = $rec->($m, $l, {});
is_deeply([ map { $_->[0]{nodeid} } @{$r->{update}} ], ['LF'], 'file inside moved dir keeps its id');
is($r->{update}[0][1]{href}, "$R/n/f", 'with its new href');
is_deeply([ map { $_->{nodeid} } @{$r->{destroy}} ], ['LD'], 'moved directory destroyed');
is(scalar @{$r->{create}}, 1, 'and created anew');

done_testing;
