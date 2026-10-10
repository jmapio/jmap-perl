#!/usr/bin/perl
# t/filenode-set.t -- FileNode/set create and destroy against a fake WebDAV
# server (backend_cmd replaced): write ordering, the mirror after each write,
# onExists, and canned bad answers Cyrus really gives (a collection DELETE
# that answers 204 and keeps the subcollections).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON;
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $R = '/dav/drive/user/u';
my $T0 = 1_700_000_000;
my (%tree, @log, %fail, $bogus_delete, $deadprops_stored);
my $etag = 0;
sub reset_tree {
  %tree = ($R => { href => $R, isCollection => 1, etag => 'r', modified => $T0, dead => {} });
  @log = ();
}
sub kids { my $p = shift; return sort grep { m{^\Q$p\E/[^/]+\z} } keys %tree }

no warnings qw(redefine once);
*JMAP::ImapDB::get_blob = sub { my ($Self, $id) = @_; return $id eq 'f-x' ? ('text/plain', 'uploaded') : $id eq 'f-y' ? ('text/x-y', 'second!') : () };
*JMAP::ImapDB::backend_cmd = sub {
  my ($Self, $cmd, $path, @a) = @_;
  die "in transaction\n" if $Self->in_transaction();
  ($path, @a) = ($a[0], $path, @a[1 .. $#a]) if $cmd eq 'files_raw';   # Raw($method, $path, ...)
  push @log, "$cmd $path";
  my $dir = $path =~ s{/\z}{}r;
  return $fail{$cmd} if $fail{$cmd} && $cmd ne 'files_put';
  if ($cmd eq 'files_prop_find') {
    my $self = $tree{$dir} or die "PROPFIND $path: HTTP 404\n";
    return [ { %$self } ] if $a[0] == 0;
    return [ { %$self }, map { +{ %{ $tree{$_} } } } kids($dir) ];
  }
  if ($cmd eq 'files_raw') {   # PROPFIND Depth 0, status only
    die "unexpected raw $a[0]" unless $a[0] eq 'PROPFIND';
    return { status => $tree{$dir} ? 207 : 404 };
  }
  if ($cmd eq 'files_put') {
    my ($bytes, %o) = @a;
    return { status => $fail{files_put} } if $fail{files_put};
    return { status => 412 } if $o{if_none_match} && $tree{$path};
    return { status => 412 } if defined $o{if_match} && (!$tree{$path} || $tree{$path}{etag} ne $o{if_match});
    (my $p = $path) =~ s{/[^/]+\z}{};
    return { status => 409 } unless $tree{$p};
    # a PUT over an existing resource keeps its dead properties, as servers do
    $tree{$path} = { href => $path, isCollection => 0, etag => 'e' . ++$etag, size => length $bytes,
                     type => $o{type}, modified => $T0 + $etag, dead => ($tree{$path} ? $tree{$path}{dead} : {}) };
    return { status => 201, etag => "e$etag" };
  }
  if ($cmd eq 'files_mkcol') {
    return 405 if $tree{$path};
    $tree{$path} = { href => $path, isCollection => 1, etag => 'c' . ++$etag, modified => $T0, dead => {} };
    return 201;
  }
  if ($cmd eq 'files_delete') {
    return 404 unless $tree{$dir};
    if ($tree{$dir}{isCollection}) {
      my @sub = grep { m{^\Q$dir\E/} } keys %tree;
      return 500 if $tree{$dir}{broken};
      if ($bogus_delete && grep { $tree{$_}{isCollection} } @sub) {
        # Cyrus: removes the files only, answers 204, and from then on
        # answers 500 to a DELETE of this collection
        delete $tree{$_} for grep { !$tree{$_}{isCollection} } kids($dir);
        $tree{$dir}{broken} = 1;
        return 204;
      }
      delete $tree{$_} for @sub;
    }
    delete $tree{$dir};
    return 204;
  }
  if ($cmd eq 'files_move') {
    my ($to, %o) = @a;
    $to =~ s{/\z}{};
    return 404 unless $tree{$dir};
    (my $tp = $to) =~ s{/[^/]+\z}{};
    return 409 unless $tree{$tp} && $tree{$tp}{isCollection};
    return 403 if index("$to/", "$dir/") == 0;   # into itself
    my $existed = $tree{$to};
    if ($existed) {
      return 412 unless $o{overwrite};
      delete $tree{$_} for grep { $_ eq $to || m{^\Q$to\E/} } keys %tree;
    }
    for my $h (grep { $_ eq $dir || m{^\Q$dir\E/} } keys %tree) {
      my $n = $to . substr($h, length $dir);
      $tree{$n} = { %{ delete $tree{$h} }, href => $n };
      $tree{$n}{etag} = 'm' . ++$etag unless $tree{$n}{isCollection};   # Cyrus: a file's ETag changes on MOVE
    }
    return $existed ? 204 : 201;
  }
  if ($cmd eq 'files_prop_patch') {
    my ($props) = @a;
    return 0 unless $tree{$dir};
    if ($deadprops_stored) {
      for my $k (keys %$props) {
        if (defined $props->{$k}) { $tree{$dir}{dead}{$k} = "$props->{$k}" } else { delete $tree{$dir}{dead}{$k} }
      }
    }
    return 1;
  }
  die "unexpected $cmd";
};
use warnings 'redefine';

my $db = JMAP::ImapDB->new('settest');
$db->{change_cb} = sub {};
sub features {
  my %f = @_;
  $db->begin();
  $db->dupdate('iserver', { webdavFeatures => encode_json({ etagIsContent => 0, deadProps => 0, %f }) });
  $db->commit();
  delete $db->{_filefeatures};
}
$db->begin();
$db->dinsert('iserver', { username => 'u', webdavURL => "http://dav.example$R/" });
$db->commit();
features();
my $api = JMAP::API->new($db);

reset_tree();
$db->sync_files();
sub rows {
  $db->begin();
  my $r = { map { $_->{href} => $_ } @{ $db->filenode_rows() } };
  $db->commit();
  return $r;
}
my $home = rows()->{$R}{nodeid};
sub set { my ($r) = $api->api_FileNode_set({ accountId => $db->accountid(), @_ }); return $r }

# --- creates, ordered by #ref, WebDAV first
my $res = set(create => {
  f => { parentId => '#d', name => "caf\x{e9}.txt", blobId => 'f-x', executable => JSON::true,
         modified => '2001-02-03T04:05:06Z' },
  d => { parentId => $home, name => 'dir' },
});
is($res->[0], 'FileNode/set', 'FileNode/set answers');
my $set = $res->[1];
ok($set->{created}{d} && $set->{created}{f}, 'both created') or diag explain $set;
is_deeply([ grep { /mkcol|put/ } @log ], [ "files_mkcol $R/dir", "files_put $R/dir/caf\x{e9}.txt" ], 'directory before the file in it');
my $rows = rows();
ok($rows->{"$R/dir/caf\x{e9}.txt"}, 'the mirror has the file under its character name');
is($rows->{"$R/dir/caf\x{e9}.txt"}{nodeid}, $set->{created}{f}{id}, 'with the id returned');
is($set->{created}{f}{size}, 8, 'size returned');
is($set->{created}{f}{type}, 'text/plain', 'type defaulted from the blob');
ok(!exists $set->{created}{f}{modified} && !exists $set->{created}{f}{executable}, 'sent values not echoed');
is($set->{created}{f}{parentId}, $set->{created}{d}{id}, 'a resolved #ref parent is returned');
is($rows->{"$R/dir/caf\x{e9}.txt"}{modified}, $T0 + $etag, 'the modified column stays the server value');
is_deeply(decode_json($rows->{"$R/dir/caf\x{e9}.txt"}{deadprops}),
  { executable => 1, modified => '2001-02-03T04:05:06Z' }, 'client values in deadprops');
ok(!grep({ /prop_patch/ } @log), 'no PROPPATCH where the server does not store dead properties');
$db->sync_files();
is(rows()->{"$R/dir/caf\x{e9}.txt"}{nodeid}, $set->{created}{f}{id}, 'a sync keeps the non-ASCII node');
ok(rows()->{"$R/dir/caf\x{e9}.txt"}{deadprops}, 'and its mirror-only dead properties');
my ($dirid, $fid) = ($set->{created}{d}{id}, $set->{created}{f}{id});

# dead properties go to the server where it stores them; a directory at "$href/"
features(deadProps => 1);
$deadprops_stored = 1;
@log = ();
$set = set(create => { e => { parentId => $dirid, name => 'sub', isSubscribed => JSON::false } })->[1];
ok($set->{created}{e}, 'directory with a dead property') or diag explain $set;
ok((grep { $_ eq "files_prop_patch $R/dir/sub/" } @log), 'PROPPATCH of a directory has the trailing slash') or diag explain \@log;
is($tree{"$R/dir/sub"}{dead}{isSubscribed}, 0, 'stored on the server as 0');
my $subid = $set->{created}{e}{id};
my $seq = rows()->{"$R/dir/sub"}{jmodseq};
$db->sync_files();
is(rows()->{"$R/dir/sub"}{jmodseq}, $seq, 'the next sync reads the dead properties back as equal: no spurious change');

# a same-name replace is one PUT onto the old resource: its dead properties are not the new node's
$set = set(create => { o => { parentId => $dirid, name => 'ow.txt', blobId => 'f-x', executable => JSON::true,
                              created => '2000-01-01T00:00:00Z' } })->[1];
is($tree{"$R/dir/ow.txt"}{dead}{executable}, '1', 'old resource has a dead executable');
$set = set(onExists => 'replace', create => { o => { parentId => $dirid, name => 'ow.txt', blobId => 'f-x',
                                                     isSubscribed => JSON::false } })->[1];
ok($set->{created}{o}, 'replaced') or diag explain $set;
is_deeply($tree{"$R/dir/ow.txt"}{dead}, { isSubscribed => '0' }, 'the server keeps only what the client sent');
is_deeply(decode_json(rows()->{"$R/dir/ow.txt"}{deadprops}), { isSubscribed => '0' }, 'and so does the mirror');
is($set->{created}{o}{executable}, JSON::false, 'the new node is not executable');
features();
$deadprops_stored = 0;

# --- clashes
$set = set(create => { a => { parentId => $dirid, name => "caf\x{e9}.txt", blobId => 'f-x' } })->[1];
is_deeply($set->{notCreated}{a}, { type => 'alreadyExists', existingId => $fid }, 'alreadyExists with existingId');
$set = set(compareCaseInsensitively => JSON::true,
           create => { a => { parentId => $dirid, name => "CAF\x{c9}.TXT", blobId => 'f-x' } })->[1];
is($set->{notCreated}{a}{existingId}, $fid, 'compareCaseInsensitively');
$set = set(onExists => 'rename', create => { a => { parentId => $dirid, name => "caf\x{e9}.txt", blobId => 'f-x' } })->[1];
is($set->{created}{a}{name}, "caf\x{e9}[2].txt", 'rename');
@log = ();
$set = set(onExists => 'replace', create => { a => { parentId => $dirid, name => "caf\x{e9}.txt", blobId => 'f-x' } })->[1];
ok($set->{created}{a}{id} && $set->{created}{a}{id} ne $fid, 'replace makes a new node');
is_deeply($set->{destroyed}, [ $fid ], 'and destroys the old one');
ok(!grep({ /delete/ } @log), 'a file over a file is one PUT, no DELETE');
ok((grep { $_ eq "files_put $R/dir/caf\x{e9}.txt" } @log), 'the PUT');
$fid = $set->{created}{a}{id};
$set = set(onExists => 'replace', create => { a => { parentId => $home, name => 'dir', blobId => 'f-x' } })->[1];
is($set->{notCreated}{a}{type}, 'nodeHasChildren', 'replacing a non-empty directory needs onDestroyRemoveChildren');

# a server that is ahead of the mirror: 412 becomes alreadyExists, and the mirror catches up
$tree{"$R/dir/late.txt"} = { href => "$R/dir/late.txt", isCollection => 0, etag => 'z', size => 1, modified => $T0, dead => {} };
$set = set(create => { a => { parentId => $dirid, name => 'late.txt', blobId => 'f-x' } })->[1];
is($set->{notCreated}{a}{type}, 'alreadyExists', 'a 412 is alreadyExists');
is($set->{notCreated}{a}{existingId}, rows()->{"$R/dir/late.txt"}{nodeid}, 'naming the node the refresh found');

# a server that refuses
$fail{files_put} = 403;
$set = set(create => { a => { parentId => $dirid, name => 'no.txt', blobId => 'f-x' } })->[1];
is($set->{notCreated}{a}{type}, 'forbidden', '403 is forbidden');
delete $fail{files_put};

# validation never reaches the server
@log = ();
$set = set(create => {
  n => { parentId => $dirid, name => '' }, p => { parentId => $fid, name => 'x' },
  b => { parentId => $dirid, name => 'y', blobId => 'f-nosuch' },
  t => { parentId => $dirid, name => 'z', blobId => 'f-x', type => 'text' },
  c => { parentId => $dirid, name => 'w', modified => 'yesterday' },
  x => { parentId => $dirid, name => 'v', executable => 'yes' },
  r => { parentId => '#r', name => 'loop' },
  s => 'not an object',
})->[1];
is($set->{notCreated}{s}{type}, 'invalidProperties', 'a non-object create is invalidProperties');
is($set->{notCreated}{$_}{type}, 'invalidProperties', "$_ invalid") for qw(n p b t c x r);
is_deeply($set->{notCreated}{c}{properties}, ['modified'], 'bad timestamp');
is_deeply($set->{notCreated}{x}{properties}, ['executable'], 'non-boolean executable');
ok(!grep({ /put|mkcol/ } @log), 'nothing written');
is(set(onExists => 'unchanged', create => {})->[1]{type}, 'invalidArguments', 'onExists unchanged');

# --- destroys
$set = set(destroy => [ $dirid ])->[1];
is($set->{notDestroyed}{$dirid}{type}, 'nodeHasChildren', 'nodeHasChildren');
ok($tree{"$R/dir"}, 'and nothing deleted');

# the mirror can be behind the server: a member it has never seen still counts
$set = set(create => { e => { parentId => $home, name => 'empty' } })->[1];
my $emptyid = $set->{created}{e}{id};
$tree{"$R/empty/unseen"} = { href => "$R/empty/unseen", isCollection => 0, etag => 'u', size => 1, modified => $T0, dead => {} };
@log = ();
$set = set(destroy => [ $emptyid ])->[1];
is($set->{notDestroyed}{$emptyid}{type}, 'nodeHasChildren', 'a child only the server knows is nodeHasChildren');
ok($tree{"$R/empty/unseen"} && $tree{"$R/empty"}, 'and nothing is deleted');
ok(!grep({ /files_delete/ } @log), 'no DELETE was sent');
my $unseen = rows()->{"$R/empty/unseen"};
ok($unseen, 'the directory was re-listed: the mirror now has the child');
$set = set(onDestroyRemoveChildren => JSON::true, destroy => [ $emptyid ])->[1];
is_deeply([ sort @{ $set->{destroyed} } ], [ sort $emptyid, $unseen->{nodeid} ], 'with the flag both go, the child listed');
ok(!$tree{"$R/empty"}, 'gone from the server');
# with the flag, a member the mirror never saw has no id: it simply goes
$set = set(create => { e => { parentId => $home, name => 'empty2' } })->[1];
$emptyid = $set->{created}{e}{id};
$tree{"$R/empty2/unseen"} = { href => "$R/empty2/unseen", isCollection => 0, etag => 'u', size => 1, modified => $T0, dead => {} };
$set = set(onDestroyRemoveChildren => JSON::true, destroy => [ $emptyid ])->[1];
is_deeply($set->{destroyed}, [ $emptyid ], 'an unseen child is deleted with its directory, and has no id to list');
ok(!$tree{"$R/empty2/unseen"}, 'it is gone from the server');
# onExists replace of a directory checks the server too
$set = set(create => { e => { parentId => $home, name => 'empty3' } })->[1];
$emptyid = $set->{created}{e}{id};
$tree{"$R/empty3/unseen"} = { href => "$R/empty3/unseen", isCollection => 0, etag => 'u', size => 1, modified => $T0, dead => {} };
$set = set(onExists => 'replace', create => { f => { parentId => $home, name => 'empty3', blobId => 'f-x' } })->[1];
is($set->{notCreated}{f}{type}, 'nodeHasChildren', 'onExists replace of a directory with an unseen child');
ok($tree{"$R/empty3/unseen"} && $tree{"$R/empty3"}{isCollection}, 'and nothing is deleted');
# children destroyed in the same call are not "other" members
$set = set(create => { d => { parentId => $home, name => 'pair' }, c => { parentId => '#d', name => 'c', blobId => 'f-x' } })->[1];
my @pair = ($set->{created}{d}{id}, $set->{created}{c}{id});
$set = set(destroy => \@pair)->[1];
is_deeply([ sort @{ $set->{destroyed} } ], [ sort @pair ], 'a directory with its only child, in one call');

# Cyrus: DELETE of a collection with subcollections answers 204, removes
# only its files and keeps itself and the subcollections
$bogus_delete = 1;
$tree{"$R/dir/sub/deep"} = { href => "$R/dir/sub/deep", isCollection => 1, etag => 'q', modified => $T0, dead => {} };
$tree{"$R/dir/sub/deep/f"} = { href => "$R/dir/sub/deep/f", isCollection => 0, etag => 'q2', size => 1, modified => $T0, dead => {} };
$db->sync_files();
my $all = rows();
my @under = map { $_->{nodeid} } grep { $_->{href} =~ m{^\Q$R\E/dir/} } values %$all;
@log = ();
$set = set(onDestroyRemoveChildren => JSON::true, destroy => [ $dirid ])->[1];
is_deeply([ sort @{ $set->{destroyed} } ], [ sort $dirid, @under ], 'every descendant listed') or diag explain $set;
is_deeply([ grep { m{^\Q$R\E/dir} } keys %tree ], [], 'the whole tree is gone from the server despite the 204') or diag explain \@log;
is(scalar(grep { $_->{href} =~ m{^\Q$R\E/dir} } values %{ rows() }), 0, 'and from the mirror');
is_deeply([ grep { /files_delete/ } @log ], [ map { "files_delete $R/$_/" } 'dir/sub/deep', 'dir/sub', 'dir' ],
  'subcollections deleted deepest first, so no DELETE ever meets one');
$bogus_delete = 0;

# a 2xx is not trusted: a collection still there after its DELETE is serverFail
$set = set(create => { d => { parentId => $home, name => 'sticky' } })->[1];
my $sticky = $set->{created}{d}{id};
{
  no warnings 'redefine';
  my $orig = \&JMAP::ImapDB::backend_cmd;
  local *JMAP::ImapDB::backend_cmd = sub { push(@log, "files_delete $_[2]"), return 204 if $_[1] eq 'files_delete'; goto &$orig };
  $set = set(destroy => [ $sticky ])->[1];
}
is($set->{notDestroyed}{$sticky}{type}, 'serverFail', 'a DELETE that answered 204 but left the collection');
ok(rows()->{"$R/sticky"}, 'the mirror keeps it');

# destroy and create of the same name in one call, children before parents
$set = set(create => { d => { parentId => $home, name => 'p' }, c => { parentId => '#d', name => 'c', blobId => 'f-x' } })->[1];
my ($p, $c) = ($set->{created}{d}{id}, $set->{created}{c}{id});
$set = set(destroy => [ $p, $c ], create => { n => { parentId => $home, name => 'p', blobId => 'f-x' } })->[1];
is_deeply([ sort @{ $set->{destroyed} } ], [ sort $p, $c ], 'a directory and its child destroyed together without the flag');
ok($set->{created}{n}, 'and a file takes the freed name');
is($tree{"$R/p"}{isCollection}, 0, 'on the server');

$set = set(destroy => [ $home, 'Lnope' ])->[1];
is($set->{notDestroyed}{$home}{type}, 'forbidden', 'home');
is($set->{notDestroyed}{Lnope}{type}, 'notFound', 'unknown');

# a failed child DELETE keeps its parent
$set = set(create => { d => { parentId => $home, name => 'q' }, c => { parentId => '#d', name => 'c', blobId => 'f-x' } })->[1];
($p, $c) = ($set->{created}{d}{id}, $set->{created}{c}{id});
{
  no warnings 'redefine';
  my $orig = \&JMAP::ImapDB::backend_cmd;
  local *JMAP::ImapDB::backend_cmd = sub { return 403 if $_[1] eq 'files_delete' && $_[2] eq "$R/q/c"; goto &$orig };
  $set = set(destroy => [ $p, $c ])->[1];
}
is($set->{notDestroyed}{$c}{type}, 'forbidden', 'the child DELETE failed');
is($set->{notDestroyed}{$p}{type}, 'nodeHasChildren', 'so the parent is not deleted over it');
ok($tree{"$R/q/c"}, 'the child is still on the server');

# --- updates (Task 8): moves, renames, content, properties
sub get { my ($r) = $api->api_FileNode_get({ accountId => $db->accountid(), ids => [ @_ ] }); return { map { $_->{id} => $_ } @{ $r->[1]{list} } } }
sub content { my $h = shift; return $tree{$h} ? "$tree{$h}{size}:$tree{$h}{type}" : undef }
$set = set(create => {
  U => { parentId => $home, name => 'U' },
  V => { parentId => '#U', name => 'V' },
  a => { parentId => '#U', name => 'a.txt', blobId => 'f-x' },
  b => { parentId => '#U', name => 'b.txt', blobId => 'f-y' },
  c => { parentId => '#U', name => 'c.txt', blobId => 'f-x', type => 'text/x-c' },
})->[1];
my %id = map { $_ => $set->{created}{$_}{id} } qw(U V a b c);
ok(!grep({ !$id{$_} } keys %id), 'update fixture created') or diag explain $set;

# a swap: unique names at every step, so one node is parked under a temporary name
@log = ();
$set = set(update => { $id{a} => { name => 'b.txt' }, $id{b} => { name => 'a.txt' } })->[1];
is_deeply([ sort keys %{ $set->{updated} || {} } ], [ sort @id{qw(a b)} ], 'swap two names') or diag explain $set;
is($set->{updated}{$id{a}}, undef, 'nothing to report beyond what was asked');
my @moves = grep { /files_move/ } @log;
is(scalar @moves, 3, 'three MOVEs');
like($moves[2], qr{/\.~tmp~}, 'one node was parked under a temporary name, and moved on last') or diag explain \@moves;
is(content("$R/U/a.txt"), '7:text/x-y', 'the server has b\'s content at a.txt');
is(content("$R/U/b.txt"), '8:text/plain', 'and a\'s at b.txt');
my $g = get(@id{qw(a b)});
is($g->{$id{a}}{name}, 'b.txt', 'a keeps its id under its new name');
is($g->{$id{b}}{name}, 'a.txt', 'and so does b');
ok(!grep({ /~tmp~/ } keys %tree), 'no temporary name left behind');
$db->sync_files();
is(rows()->{"$R/U/b.txt"}{nodeid}, $id{a}, 'a sync agrees');

# a rotation of three
$set = set(update => { $id{a} => { name => 'c.txt' }, $id{c} => { name => 'a.txt' }, $id{b} => { name => 'b.txt' } })->[1];
is(scalar keys %{ $set->{updated} || {} }, 3, 'a rotation of three') or diag explain $set;
$g = get(@id{qw(a b c)});
is_deeply([ map { $g->{$id{$_}}{name} } qw(a b c) ], [ 'c.txt', 'b.txt', 'a.txt' ], 'every node where it was sent');
is(content("$R/U/c.txt"), '8:text/plain', 'content followed the nodes');

# into a directory made in the same call
$set = set(create => { W => { parentId => $id{U}, name => 'W' } },
           update => { $id{c} => { parentId => '#W' } })->[1];
ok($set->{created}{W} && exists $set->{updated}{$id{c}}, 'move into a directory created in the same call') or diag explain $set;
ok($tree{"$R/U/W/a.txt"}, 'on the server');
is(get($id{c})->{$id{c}}{parentId}, $set->{created}{W}{id}, 'and in the mirror');
$id{W} = $set->{created}{W}{id};

# a directory into its own child; then a reversal that is valid in the final tree
@log = ();
$set = set(update => { $id{U} => { parentId => $id{V} } })->[1];
is($set->{notUpdated}{$id{U}}{type}, 'invalidProperties', 'a directory into its own child');
is_deeply($set->{notUpdated}{$id{U}}{properties}, ['parentId'], 'on parentId');
ok(!grep({ /files_move/ } @log), 'nothing sent');
$set = set(update => { $id{U} => { parentId => $id{V} }, $id{V} => { parentId => $home } })->[1];
ok(exists $set->{updated}{$id{U}} && exists $set->{updated}{$id{V}}, 'V moves out of U, then U into V') or diag explain $set;
ok($tree{"$R/V/U/b.txt"} && $tree{"$R/V/U/W/a.txt"}, 'the server has the new tree');
my $r = rows();
is($r->{"$R/V/U/W/a.txt"}{nodeid}, $id{c}, 'descendants\' hrefs followed in the mirror');
$db->sync_files();
is(rows()->{"$R/V/U/W/a.txt"}{nodeid}, $id{c}, 'and a sync agrees');
$set = set(update => { $id{V} => { parentId => $id{U} }, $id{U} => { parentId => $home } })->[1];
ok(exists $set->{updated}{$id{U}} && exists $set->{updated}{$id{V}}, 'and back') or diag explain $set;
ok($tree{"$R/U/V"} && $tree{"$R/U/b.txt"}, 'the server has the original tree again');

# clashes with a node that stays
$set = set(update => { $id{a} => { name => 'b.txt' } })->[1];
is_deeply($set->{notUpdated}{$id{a}}, { type => 'alreadyExists', existingId => $id{b} }, 'alreadyExists with existingId');
$set = set(compareCaseInsensitively => JSON::true, update => { $id{a} => { name => 'B.TXT' } })->[1];
is($set->{notUpdated}{$id{a}}{existingId}, $id{b}, 'compareCaseInsensitively');
$set = set(update => { $id{a} => { name => 'B.TXT' } })->[1];
ok(exists $set->{updated}{$id{a}}, 'case-sensitive by default') or diag explain $set;
$set = set(compareCaseInsensitively => JSON::true, update => { $id{a} => { name => 'c.txt' } })->[1];
ok(exists $set->{updated}{$id{a}}, 'a change of case alone is no clash') or diag explain $set;
$set = set(onExists => 'rename', update => { $id{a} => { name => 'b.txt' } })->[1];
is($set->{updated}{$id{a}}{name}, 'b[2].txt', 'onExists rename reports the new name');
is(get($id{a})->{$id{a}}{name}, 'b[2].txt', 'and uses it');
@log = ();
$set = set(onExists => 'replace', update => { $id{a} => { name => 'b.txt' } })->[1];
ok(exists $set->{updated}{$id{a}}, 'onExists replace') or diag explain $set;
is_deeply($set->{destroyed}, [ $id{b} ], 'the replaced node is destroyed');
ok((grep { /files_move/ } @log) == 1 && !grep({ /files_delete/ } @log), 'a file over a file is one MOVE, no DELETE');
is(content("$R/U/b.txt"), '8:text/plain', 'a\'s content now at b.txt');
ok(!get($id{b})->{$id{b}}, 'b is gone');
$set = set(create => { b => { parentId => $id{U}, name => 'b.txt', blobId => 'f-y' } }, update => { $id{a} => { name => 'a.txt' } })->[1];
ok($set->{created}{b} && exists $set->{updated}{$id{a}}, 'a create takes the name a move leaves') or diag explain $set;
$id{b} = $set->{created}{b}{id};
$set = set(update => { $id{a} => { name => 'x.txt' } }, create => { a => { parentId => $id{U}, name => 'a.txt', blobId => 'f-y' } })->[1];
ok($set->{created}{a} && exists $set->{updated}{$id{a}}, 'whatever order the client lists them in') or diag explain $set;
my $newa = $set->{created}{a}{id};
$set = set(update => { $id{a} => { name => 'a.txt' } }, destroy => [ $newa ])->[1];
ok(exists $set->{updated}{$id{a}} && $set->{destroyed}, 'a move into the name a destroy frees') or diag explain $set;

# R6: destroying a directory while its only child moves out
$set = set(create => { D => { parentId => $home, name => 'D' }, k => { parentId => '#D', name => 'k.txt', blobId => 'f-x' } })->[1];
my ($D, $k) = ($set->{created}{D}{id}, $set->{created}{k}{id});
@log = ();
$set = set(destroy => [ $D ], update => { $k => { parentId => $id{U} } })->[1];
is_deeply($set->{destroyed}, [ $D ], 'the directory is destroyed') or diag explain $set;
my @ops = grep { /files_move|files_delete/ } @log;
like($ops[0] // '', qr/files_move/, 'the move runs before the DELETE') or diag explain \@ops;
ok(exists $set->{updated}{$k}, 'after its child moved out');
ok($tree{"$R/U/k.txt"} && !$tree{"$R/D"}, 'on the server');
# ... but a child that fails to move keeps its directory
$set = set(create => { D => { parentId => $home, name => 'D' }, k => { parentId => '#D', name => 'b.txt', blobId => 'f-x' } })->[1];
($D, my $k2) = ($set->{created}{D}{id}, $set->{created}{k}{id});
$set = set(destroy => [ $D ], update => { $k2 => { parentId => $id{U} } })->[1];
is($set->{notUpdated}{$k2}{type}, 'alreadyExists', 'the move clashes');
is($set->{notDestroyed}{$D}{type}, 'nodeHasChildren', 'so the directory stays');
set(onDestroyRemoveChildren => JSON::true, destroy => [ $D ]);

# content and properties
@log = ();
$set = set(update => { $id{a} => { name => 'moved.txt', blobId => 'f-y' } })->[1];
my $u = $set->{updated}{$id{a}};
is($u->{size}, 7, 'new content: size reported');
is($u->{type}, 'text/x-y', 'type from the blob reported');
like($u->{blobId} // '', qr/^d-\Q$id{a}\E-/, 'the new blobId');
is(content("$R/U/moved.txt"), '7:text/x-y', 'a move and new content in one update (If-Match after the MOVE changed the ETag)')
  or diag explain \@log;
is(get($id{a})->{$id{a}}{blobId}, $u->{blobId}, 'the node carries the new blobId');
$set = set(update => { $id{a} => { blobId => 'f-x', size => 3 } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['size'], 'a size that does not match the blob');
$set = set(update => { $id{a} => { blobId => 'f-nosuch' } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['blobId'], 'an unknown blob');
$set = set(update => { $id{U} => { blobId => 'f-x' } })->[1];
is_deeply($set->{notUpdated}{$id{U}}{properties}, ['blobId'], 'a directory has no content');
$set = set(update => { $id{a} => { blobId => undef } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['blobId'], 'a file cannot lose its content');

$set = set(update => { $id{a} => { executable => JSON::true, accessed => '2026-01-02T03:04:05Z', modified => undef,
                                    isSubscribed => JSON::false, created => '2020-01-01T00:00:00Z' } })->[1];
$u = $set->{updated}{$id{a}};
ok($u && $u->{modified}, 'a null modified is set to now, and reported') or diag explain $set;
ok(!exists $u->{accessed}, 'a value the client gave is not');
$g = get($id{a})->{$id{a}};
is($g->{executable}, JSON::true, 'executable');
is($g->{isSubscribed}, JSON::false, 'isSubscribed');
is($g->{accessed}, '2026-01-02T03:04:05Z', 'accessed');
is($g->{created}, '2020-01-01T00:00:00Z', 'created');
is($g->{modified}, $u->{modified}, 'modified');
is(rows()->{"$R/U/moved.txt"}{modified}, $tree{"$R/U/moved.txt"}{modified}, 'the columns keep the server values (R4)');
$set = set(update => { $id{a} => { executable => undef } })->[1];
is(get($id{a})->{$id{a}}{executable}, JSON::false, 'a null executable is its default, false');

$set = set(update => { $id{a} => { type => 'text/markdown; charset=utf-8' } })->[1];
ok(exists $set->{updated}{$id{a}}, 'a new type without new content') or diag explain $set;
is(get($id{a})->{$id{a}}{type}, 'text/markdown', 'is served');
is_deeply(decode_json(rows()->{"$R/U/moved.txt"}{deadprops})->{type}, 'text/markdown', 'from the dead properties');
$db->sync_files();
is(get($id{a})->{$id{a}}{type}, 'text/markdown', 'and survives a sync');
$set = set(update => { $id{a} => { blobId => 'f-x' } })->[1];
is($set->{updated}{$id{a}}{type}, 'text/plain', 'new content brings the blob\'s type');
ok(!exists decode_json(rows()->{"$R/U/moved.txt"}{deadprops})->{type}, 'and drops the client-set one');
is(content("$R/U/moved.txt"), '8:text/plain', 'on the server');
$set = set(update => { $id{a} => { type => 'nonsense' } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['type'], 'a type that is not a media type');
$set = set(update => { $id{U} => { type => 'text/plain' } })->[1];
is_deeply($set->{notUpdated}{$id{U}}{properties}, ['type'], 'a directory has no type');

# dead properties go to a server that stores them; a directory at "$href/"
features(deadProps => 1);
$deadprops_stored = 1;
@log = ();
$set = set(update => { $id{U} => { isSubscribed => JSON::false } })->[1];
ok(exists $set->{updated}{$id{U}}, 'a dead property on a directory');
ok((grep { $_ eq "files_prop_patch $R/U/" } @log), 'PROPPATCHed with a trailing slash') or diag explain \@log;
is($tree{"$R/U"}{dead}{isSubscribed}, '0', 'stored');
features();
$deadprops_stored = 0;

# immutable and server-set properties; whole objects sent back
my $whole = get($id{a})->{$id{a}};
$set = set(update => { $id{a} => { %$whole, name => 'whole.txt' } })->[1];
ok(exists $set->{updated}{$id{a}}, 'a whole object with one change') or diag explain $set;
is(get($id{a})->{$id{a}}{name}, 'whole.txt', 'applied');
$set = set(update => { $id{a} => { nodeType => 'directory' } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['nodeType'], 'nodeType is immutable');
$set = set(update => { $id{a} => { id => 'Lother', size => 1, myRights => {} } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, [ qw(id myRights size) ], 'server-set properties');
$set = set(update => { $id{a} => { shareWith => { u2 => {} } } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['shareWith'], 'shareWith: not yet');
$set = set(update => { $id{a} => { name => 'x/y' }, $id{b} => { parentId => $id{a} }, $id{c} => { parentId => 'Lnosuch' } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['name'], 'a bad name');
is_deeply($set->{notUpdated}{$id{b}}{properties}, ['parentId'], 'a file is no parent');
is_deeply($set->{notUpdated}{$id{c}}{properties}, ['parentId'], 'an unknown parent');
$set = set(update => { $home => { name => 'elsewhere' }, Lnosuch => { name => 'x' }, $id{a} => 'nope' })->[1];
is_deeply($set->{notUpdated}{$home}{properties}, ['name'], 'the home cannot be renamed');
is($set->{notUpdated}{Lnosuch}{type}, 'notFound', 'an unknown node');
is($set->{notUpdated}{$id{a}}{type}, 'invalidPatch', 'a patch that is not an object is invalidPatch (RFC 8620 S5.3)');
$set = set(update => { $id{a} => { parentId => undef } })->[1];
is_deeply($set->{notUpdated}{$id{a}}{properties}, ['parentId'], 'no top-level nodes');

# a parked node whose final MOVE fails does not keep its temporary name
{
  no warnings 'redefine';
  my $orig = \&JMAP::ImapDB::backend_cmd;
  my $n = 0;
  local *JMAP::ImapDB::backend_cmd = sub {
    return 500 if $_[1] eq 'files_move' && $_[2] =~ /~tmp~/ && !$n++;
    goto &$orig;
  };
  $set = set(update => { $id{a} => { name => 'b.txt' }, $id{b} => { name => 'whole.txt' } })->[1];
}
my ($ok_id, $bad_id) = exists $set->{updated}{$id{a}} ? ($id{a}, $id{b}) : ($id{b}, $id{a});
is($set->{notUpdated}{$bad_id}{type}, 'serverFail', 'the parked node\'s move fails') or diag explain $set;
ok(!grep({ /~tmp~/ } keys %tree), 'it is not left under its temporary name');
$g = get(@id{qw(a b)});
is(scalar(grep { $tree{"$R/U/$_"} } map { $_->{name} } values %$g), 2, 'the mirror names both as the server does');

# --- fix round 1
sub mk { my %c = @_; my $s = set(create => \%c)->[1]; die explain $s if $s->{notCreated}; return { map { $_ => $s->{created}{$_}{id} } keys %c } }
# replace of an ancestor: the mover steps out before its old directory goes
my $x = mk(R => { parentId => $home, name => 'R1' }, s => { parentId => '#R', name => 'sub' },
           a => { parentId => '#s', name => 'a.txt', blobId => 'f-y' });
$set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
           update => { $x->{a} => { parentId => $x->{R}, name => 'sub' } })->[1];
ok(exists $set->{updated}{$x->{a}}, 'a file replaces its own parent directory') or diag explain $set;
is_deeply($set->{destroyed}, [ $x->{s} ], 'which is destroyed');
is(content("$R/R1/sub"), '7:text/x-y', 'and the file survives, under the name') or diag explain [ grep { m{/R1} } keys %tree ];
ok(!grep({ /~tmp~/ } keys %tree), 'no temporary name left');
$x = mk(s => { parentId => $x->{R}, name => 'sub2' }, a => { parentId => '#s', name => 'a.txt', blobId => 'f-y' },
        o => { parentId => '#s', name => 'other.txt', blobId => 'f-x' }, R => { parentId => $home, name => 'R2' });
$set = set(onExists => 'replace', update => { $x->{a} => { parentId => $x->{R}, name => 'x' } })->[1];
ok(exists $set->{updated}{$x->{a}}, 'a plain move first') or diag explain $set;
$set = set(onExists => 'replace', update => { $x->{a} => { parentId => (rows()->{"$R/R1"}{nodeid}), name => 'sub2' } })->[1];
is($set->{notUpdated}{$x->{a}}{type}, 'nodeHasChildren', 'replacing a directory that keeps a child needs the flag') or diag explain $set;
ok($tree{"$R/R1/sub2/other.txt"} && $tree{"$R/R2/x"}, 'and nothing moved or went');
# ... the ancestor case without the flag, where the mover was the only child
$x = mk(s => { parentId => $home, name => 'R3' }, a => { parentId => '#s', name => 'only.txt', blobId => 'f-y' });
$set = set(onExists => 'replace', update => { $x->{a} => { parentId => $home, name => 'R3' } })->[1];
ok(exists $set->{updated}{$x->{a}}, 'the only child replaces its parent, without the flag') or diag explain $set;
is(content("$R/R3"), '7:text/x-y', 'on the server');
# ... and with another child that stays, without the flag: the mover goes back
$x = mk(s => { parentId => $home, name => 'R4' }, a => { parentId => '#s', name => 'a.txt', blobId => 'f-y' },
        o => { parentId => '#s', name => 'o.txt', blobId => 'f-x' });
$set = set(onExists => 'replace', update => { $x->{a} => { parentId => $home, name => 'R4' } })->[1];
is($set->{notUpdated}{$x->{a}}{type}, 'nodeHasChildren', 'an ancestor with another child') or diag explain $set;
ok($tree{"$R/R4/a.txt"} && $tree{"$R/R4/o.txt"}, 'the mover is back where it was, nothing deleted') or diag explain [ grep { m{/R4} } keys %tree ];
is(rows()->{"$R/R4/a.txt"}{nodeid}, $x->{a}, 'the mirror agrees');
# a sibling leaving the replaced directory in the same call
$x = mk(D => { parentId => $home, name => 'R5' }, s => { parentId => '#D', name => 's2' },
        k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' }, f => { parentId => '#D', name => 'f.txt', blobId => 'f-y' });
$set = set(onExists => 'replace', update => { $x->{f} => { name => 's2' }, $x->{k} => { parentId => $x->{D}, name => 'k2.txt' } })->[1];
ok(exists $set->{updated}{$x->{f}} && exists $set->{updated}{$x->{k}}, 'the child leaves before its directory is replaced') or diag explain $set;
is_deeply($set->{destroyed}, [ $x->{s} ], 'without the flag');
ok($tree{"$R/R5/k2.txt"} && content("$R/R5/s2") eq '7:text/x-y', 'on the server');

# whole-object stripping keeps type and size beside new content
$x = mk(f => { parentId => $home, name => 'typed.txt', blobId => 'f-x' });   # text/plain
$set = set(update => { $x->{f} => { blobId => 'f-y', type => 'text/plain', size => 7 } })->[1];
ok(exists $set->{updated}{$x->{f}}, 'new content with the current type and its size') or diag explain $set;
is(content("$R/typed.txt"), '7:text/plain', 'the type sent is the one PUT, not the blob\'s');

# R6: a late destroy's name is free for a create and for a move
$x = mk(P => { parentId => $home, name => 'R6' }, D => { parentId => '#P', name => 'D' },
        k => { parentId => '#D', name => 'k.txt', blobId => 'f-x' });
$set = set(destroy => [ $x->{D} ], update => { $x->{k} => { parentId => $x->{P} } },
           create => { n => { parentId => $x->{P}, name => 'D', blobId => 'f-y' } })->[1];
is($set->{created}{n}{name}, undef, 'a create takes the name of a directory destroyed after its child moved out') or diag explain $set;
ok($set->{created}{n}, 'created');
is_deeply($set->{destroyed}, [ $x->{D} ], 'the directory is destroyed');
is(content("$R/R6/D"), '7:text/x-y', 'on the server');
$x = mk(D => { parentId => $x->{P}, name => 'D2' }, k => { parentId => '#D', name => 'k2.txt', blobId => 'f-x' },
        m => { parentId => $x->{P}, name => 'm.txt', blobId => 'f-y' });
my $P6 = rows()->{"$R/R6"}{nodeid};
$set = set(destroy => [ $x->{D} ], update => { $x->{k} => { parentId => $P6 }, $x->{m} => { name => 'D2' } })->[1];
ok(exists $set->{updated}{$x->{m}} && exists $set->{updated}{$x->{k}}, 'a move takes the name too') or diag explain $set;
is_deeply($set->{destroyed}, [ $x->{D} ], 'after the destroy');
is(content("$R/R6/D2"), '7:text/x-y', 'on the server');

# new content for a file inside a directory that moves in the same call
# (this fake changes descendants' ETags on a directory MOVE)
$x = mk(Q => { parentId => $home, name => 'R7' }, f => { parentId => '#Q', name => 'f.txt', blobId => 'f-x' });
$set = set(update => { $x->{Q} => { name => 'R7moved' }, $x->{f} => { blobId => 'f-y' } })->[1];
is($set->{updated}{$x->{f}}{size}, 7, 'a directory move and new content inside it, in one call') or diag explain $set;
is(content("$R/R7moved/f.txt"), '7:text/x-y', 'on the server');

# the holder of a replaced name must be deletable
$x = mk(L => { parentId => $home, name => 'R8' }, h => { parentId => '#L', name => 'h.txt', blobId => 'f-x' },
        m => { parentId => $home, name => 'R8m.txt', blobId => 'f-y' });
$tree{"$R/R8"}{privileges} = [ qw(read bind write-content) ];   # no unbind: its children cannot be deleted
$db->sync_files();
@log = ();
$set = set(onExists => 'replace', update => { $x->{m} => { parentId => $x->{L}, name => 'h.txt' } })->[1];
is($set->{notUpdated}{$x->{m}}{type}, 'forbidden', 'replace needs mayDelete on the node replaced') or diag explain $set;
ok(!grep({ /files_move/ } @log), 'refused before anything is sent');
delete $tree{"$R/R8"}{privileges};
$db->sync_files();

# a parked node that can be neither moved on nor put back says where it is
$x = mk(Z => { parentId => $home, name => 'R9' }, a => { parentId => '#Z', name => 'a', blobId => 'f-x' },
        b => { parentId => '#Z', name => 'b', blobId => 'f-y' });
{
  no warnings 'redefine';
  my $orig = \&JMAP::ImapDB::backend_cmd;
  local *JMAP::ImapDB::backend_cmd = sub {
    return 500 if $_[1] eq 'files_move' && $_[2] =~ /~tmp~/;
    goto &$orig;
  };
  $set = set(update => { $x->{a} => { name => 'b' }, $x->{b} => { name => 'a' } })->[1];
}
my ($bad) = keys %{ $set->{notUpdated} || {} };
like($set->{notUpdated}{$bad // ''}{description} // '', qr{left at \Q$R\E/R9/\.~tmp~}, 'the error names where the node was left')
  or diag explain $set;

# a swap with a replace: the node parked to break the cycle lies inside the
# directory being replaced, so it is parked outside it (fix round 2, N1)
for my $flag (0, 1) {
  my $n = "R10$flag";
  my $x = mk(D => { parentId => $home, name => $n }, f => { parentId => '#D', name => 'f.txt', blobId => 'f-y' },
             s => { parentId => '#D', name => 's2' }, k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' });
  $set = set(onExists => 'replace', ($flag ? (onDestroyRemoveChildren => JSON::true) : ()),
             update => { $x->{f} => { name => 's2' }, $x->{k} => { parentId => $x->{D}, name => 'f.txt' } })->[1];
  my $how = $flag ? 'with onDestroyRemoveChildren' : 'without onDestroyRemoveChildren';
  ok(exists $set->{updated}{$x->{f}} && exists $set->{updated}{$x->{k}}, "swap into a replaced directory, $how") or diag explain $set;
  is_deeply($set->{destroyed}, [ $x->{s} ], 'only the replaced directory is destroyed');
  is(content("$R/$n/f.txt"), '8:text/plain', 'k survives at D/f.txt');
  is(content("$R/$n/s2"), '7:text/x-y', 'f is now named s2');
  ok(!$tree{"$R/$n/s2/k.txt"} && !grep({ m{^\Q$R/$n/\E.*~tmp~} } keys %tree), 's2 is gone and no temporary name is left');
  my $g = get(@$x{qw(f k)});
  is($g->{$x->{k}}{name}, 'f.txt', 'the mirror agrees on k');
  is($g->{$x->{f}}{name}, 's2', 'and on f');
}

my (undef, undef, undef, $lateNot) = $db->update_filenodes({}, sub { $_[0] }, { late_destroy => [ 'Lgonealready' ] });
is_deeply($lateNot, { Lgonealready => { type => 'notFound' } }, 'a late destroy of a node already gone is notFound');

# two replaces, each displacing the other's directory (fix round 3, N2)
for my $flag (0, 1) {
  my $n = "R11$flag";
  my $x = mk(P => { parentId => $home, name => $n }, h1 => { parentId => '#P', name => 'h1' }, h2 => { parentId => '#P', name => 'h2' },
             B => { parentId => '#h1', name => 'b.txt', blobId => 'f-x' }, A => { parentId => '#h2', name => 'a.txt', blobId => 'f-y' });
  $set = set(onExists => 'replace', ($flag ? (onDestroyRemoveChildren => JSON::true) : ()),
             update => { $x->{A} => { parentId => $x->{P}, name => 'h1' }, $x->{B} => { parentId => $x->{P}, name => 'h2' } })->[1];
  my $how = $flag ? 'with onDestroyRemoveChildren' : 'without onDestroyRemoveChildren';
  ok(exists $set->{updated}{$x->{A}} && exists $set->{updated}{$x->{B}}, "two replaces of each other's directory, $how") or diag explain $set;
  is_deeply([ sort @{ $set->{destroyed} || [] } ], [ sort @$x{qw(h1 h2)} ], 'the two directories are destroyed');
  is(content("$R/$n/h1"), '7:text/x-y', 'A is at h1');
  is(content("$R/$n/h2"), '8:text/plain', 'B is at h2');
  ok(!grep({ m{^\Q$R/$n/\E.*~tmp~} } keys %tree), 'no temporary name is left');
  my $g = get(@$x{qw(A B)});
  is_deeply([ map { $g->{$x->{$_}}{name} } qw(A B) ], [ 'h1', 'h2' ], 'the mirror agrees');
}

# the safety net: whatever order the moves come in, a destroy never takes a
# node that is still to move (order_moves forced to emit them as they come)
{
  no warnings 'redefine';
  local *JMAP::FileNode::order_moves = sub { my ($m) = @_; return [ map { [$_, undef] } sort keys %$m ] };
  my $x = mk(P => { parentId => $home, name => 'R12' }, h1 => { parentId => '#P', name => 'h1' }, h2 => { parentId => '#P', name => 'h2' },
             B => { parentId => '#h1', name => 'b.txt', blobId => 'f-x' }, A => { parentId => '#h2', name => 'a.txt', blobId => 'f-y' });
  @log = ();
  $set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
             update => { $x->{A} => { parentId => $x->{P}, name => 'h1' }, $x->{B} => { parentId => $x->{P}, name => 'h2' } })->[1];
  my ($first) = sort @$x{qw(A B)};
  is($set->{notUpdated}{$first}{type}, 'nodeHasChildren', 'the safety net refuses the first replace') or diag explain $set;
  my @files = sort map { content($_) } grep { m{^\Q$R/R12/\E} && !$tree{$_}{isCollection} } keys %tree;
  is_deeply(\@files, [ '7:text/x-y', '8:text/plain' ], 'neither A nor B is lost');
  is(scalar(grep { m{^\Q$R/R12/\E.*\.txt\z|^\Q$R/R12/h[12]\z} && !$tree{$_}{isCollection} } keys %tree), 2, 'both files still exist')
    or diag explain [ grep { m{R12} } keys %tree ];
  ok(!grep({ m{^\Q$R/R12/\E.*~tmp~} } keys %tree), 'no temporary name is left');
}

ok(!$db->in_transaction(), 'no transaction left open');
done_testing;
