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
*JMAP::ImapDB::get_blob = sub { my ($Self, $id) = @_; return $id eq 'f-x' ? ('text/plain', 'uploaded') : () };
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
    (my $p = $path) =~ s{/[^/]+\z}{};
    return { status => 409 } unless $tree{$p};
    $tree{$path} = { href => $path, isCollection => 0, etag => 'e' . ++$etag, size => length $bytes,
                     type => $o{type}, modified => $T0 + $etag, dead => {} };
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
  if ($cmd eq 'files_prop_patch') {
    my ($props) = @a;
    return 0 unless $tree{$dir};
    $tree{$dir}{dead} = { %{ $tree{$dir}{dead} }, %$props } if $deadprops_stored;
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
})->[1];
is($set->{notCreated}{$_}{type}, 'invalidProperties', "$_ invalid") for qw(n p b t c x r);
is_deeply($set->{notCreated}{c}{properties}, ['modified'], 'bad timestamp');
is_deeply($set->{notCreated}{x}{properties}, ['executable'], 'non-boolean executable');
ok(!grep({ /put|mkcol/ } @log), 'nothing written');
is(set(onExists => 'unchanged', create => {})->[1]{type}, 'invalidArguments', 'onExists unchanged');

# --- destroys
$set = set(destroy => [ $dirid ])->[1];
is($set->{notDestroyed}{$dirid}{type}, 'nodeHasChildren', 'nodeHasChildren');
ok($tree{"$R/dir"}, 'and nothing deleted');

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

ok(!$db->in_transaction(), 'no transaction left open');
done_testing;
