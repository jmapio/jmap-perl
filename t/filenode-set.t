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
my (%tree, @log, %fail, $put_garbles, $bogus_delete, $deadprops_stored, $move_leaves_shell, $ci_server);
# a case-insensitive server: a path finds the collection whatever its case
sub ci { my $d = shift; return $d unless $ci_server && !$tree{$d}; my ($k) = grep { lc $_ eq lc $d } keys %tree; return $k // $d }
# sharing: each collection's own (non-inherited) ACEs, the principals the
# server knows, and an override for the answer to an ACL request
my (%acl, %principal, $acl_answer, @acl_reqs, $acl_tree, $inherits);
my $OWNER = '/dav/principals/user/u/';
my $SELF_ACE = { principal => 'self', invert => 0, grant => ['all'], deny => [], inherited => 0, protected => 0 };
sub aces_of { my $h = shift; return [ map { +{ %$_ } } @{ $acl{$h} || [ $SELF_ACE ] } ] }
my $etag = 0;
sub reset_tree {
  %tree = ($R => { href => $R, isCollection => 1, etag => 'r', modified => $T0, dead => {} });
  @log = ();
}
sub kids { my $p = shift; return sort grep { m{^\Q$p\E/[^/]+\z} } keys %tree }

no warnings qw(redefine once);
*JMAP::ImapDB::get_blob = sub { my ($Self, $id) = @_; return $id eq 'f-x' ? ('text/plain', 'uploaded') : $id eq 'f-y' ? ('text/x-y', 'second!') : $id eq 'f-e' ? ('text/plain', '') : () };
*JMAP::ImapDB::backend_cmd = sub {
  my ($Self, $cmd, $path, @a) = @_;
  die "in transaction\n" if $Self->in_transaction();
  ($path, @a) = ($a[0], $path, @a[1 .. $#a]) if $cmd eq 'files_raw';   # Raw($method, $path, ...)
  push @log, "$cmd $path";
  my $dir = $path =~ s{/\z}{}r;
  return $fail{$cmd} if $fail{$cmd} && $cmd ne 'files_put';
  if ($cmd eq 'files_prop_find') {
    my $real = ci($dir);
    my $self = $tree{$real} or die "PROPFIND $path: HTTP 404\n";
    $self = { %$self, href => $dir } if $real ne $dir;   # the server echoes the spelling asked for
    my $with = sub {   # a listing that asks for the ACL gets it, and the owner
      my $e = { %{ $_[0] } };
      return $e unless ref $a[1] eq 'HASH' && $a[1]{acl};
      $e->{owner} = $OWNER;
      $e->{acl} = $e->{isCollection} ? aces_of($e->{href})
                : [ map { +{ %$_, inherited => 1 } } @{ aces_of($e->{href} =~ s{/[^/]+\z}{}r) } ];
      return $e;
    };
    return [ $with->($self) ] if $a[0] == 0;
    return [ $with->($self), map { $with->($tree{$_}) } kids($real) ];
  }
  if ($cmd eq 'files_raw') {   # PROPFIND Depth 0, status only
    die "unexpected raw $a[0]" unless $a[0] eq 'PROPFIND';
    return { status => $principal{$path} ? 207 : 404 } if $path =~ m{^/dav/principals/};
    return { status => $tree{$dir} ? 207 : 404 };
  }
  if ($cmd eq 'files_acl_info') {
    return undef unless $tree{$dir} && $tree{$dir}{isCollection};
    # a server that inherits: the users' grants of every ancestor show as inherited ACEs
    my @inh;
    if ($inherits) {
      for (my $a = $dir =~ s{/[^/]+\z}{}r; $tree{$a}; $a =~ s{/[^/]+\z}{} or last) {
        push @inh, map { +{ %$_, inherited => 1 } } grep { $_->{principal} =~ m{/user/} } @{ $acl{$a} || [] };
        last if $a eq $R;
      }
    }
    return { aces => [ @{ aces_of($dir) }, @inh ], owner => $OWNER, ($acl_tree ? (privileges => $acl_tree) : ()),
             principalCollections => ['/dav/principals/user/'] };
  }
  if ($cmd eq 'files_set_acl') {
    my ($aces) = @a;
    push @acl_reqs, [ $dir, $aces ];
    if ($acl_answer) { my $r = $acl_answer->($dir, $aces); return $r if $r }
    # RFC 3744 S8.1.1 DAV:recognized-principal
    return { status => 403, error => 'recognized-principal' }
      if grep { $_->{principal} =~ m{^/} && !$principal{ $_->{principal} } } @$aces;
    $acl{$dir} = [ map { +{ %$_ } } @$aces ];
    return { status => 200 };
  }
  if ($cmd eq 'files_put') {
    my ($bytes, %o) = @a;
    return { status => $fail{files_put} } if $fail{files_put};
    return { status => 412 } if $o{if_none_match} && $tree{$path};
    return { status => 412 } if defined $o{if_match} && (!$tree{$path} || $tree{$path}{etag} ne $o{if_match});
    (my $p = $path) =~ s{/[^/]+\z}{};
    return { status => 409 } unless $tree{$p};
    # a PUT over an existing resource keeps its dead properties, as servers do
    # Cyrus #drive: a zero-length PUT stores the connection's previous request body
    $bytes = '<D:propfind/>' if $put_garbles && !length $bytes;
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
    $dir = ci($dir);
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
      delete $acl{$_} for @sub;
    }
    delete $tree{$dir};
    delete $acl{$dir};
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
      $acl{$n} = delete $acl{$h} if exists $acl{$h};                    # a collection keeps its own ACL
    }
    # Cyrus: a collection that held collections leaves an empty one behind
    $tree{$dir} = { href => $dir, isCollection => 1, etag => 'c' . ++$etag, modified => $T0, dead => {} }
      if $move_leaves_shell && grep { $tree{$_}{isCollection} && m{^\Q$to\E/} } keys %tree;
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

# a server that stores other bytes than it was sent (Cyrus #drive, for an
# empty body): never a node whose content is not what the client gave
$put_garbles = 1;
$set = set(create => { a => { parentId => $dirid, name => 'empty.txt', blobId => 'f-e' } })->[1];
is($set->{notCreated}{a}{type}, 'serverFail', 'a PUT the server stored wrongly is serverFail') or diag explain $set;
ok(!$tree{"$R/dir/empty.txt"}, 'and the wrong resource is deleted again');
ok(!rows()->{"$R/dir/empty.txt"}, 'and is not in the mirror');
$set = set(update => { $fid => { blobId => 'f-e' } })->[1];
is($set->{notUpdated}{$fid}{type}, 'serverFail', 'a content update the server stored wrongly is serverFail') or diag explain $set;
$put_garbles = 0;
$set = set(create => { a => { parentId => $dirid, name => 'empty.txt', blobId => 'f-e' } })->[1];
is($set->{created}{a}{size}, 0, 'a server that stores what it is sent makes a zero-byte file') or diag explain $set;
set(destroy => [ $set->{created}{a}{id} ]);

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
is_deeply($set->{notUpdated}{$id{a}}, { type => 'invalidProperties', properties => ['shareWith'] },
          'shareWith on a server without ACLs: invalidProperties (spec "Sharing")');
is(get($id{a})->{$id{a}}{shareWith}, undef, 'and it reads as null');
ok(!get($id{a})->{$id{a}}{myRights}{mayShare}, 'with mayShare false');
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

# --- fix round 4 (N3): a node the client asked to move is a mover even when
# that update is refused: no destroy in the call may take it, and no replace
# may overwrite it
sub files_under { my $p = shift; return [ sort grep { m{^\Q$p\E/} && !$tree{$_}{isCollection} } keys %tree ] }
# refused in step 1 (a bad shareWith), inside the directory a replace displaces
{
  my $x = mk(D => { parentId => $home, name => 'R13' }, f => { parentId => '#D', name => 'f.txt', blobId => 'f-y' },
             s => { parentId => '#D', name => 's2' }, k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' });
  $set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
             update => { $x->{f} => { name => 's2' },
                         $x->{k} => { parentId => $x->{D}, name => 'k.txt', shareWith => 'not an object' } })->[1];
  is($set->{notUpdated}{$x->{k}}{type}, 'invalidProperties', 'k is refused in step 1') or diag explain $set;
  is($set->{notUpdated}{$x->{f}}{type}, 'nodeHasChildren', 'so the replace that would take k with s2 is refused') or diag explain $set;
  ok(!$set->{destroyed}, 'nothing is destroyed');
  is_deeply(files_under("$R/R13"), [ "$R/R13/f.txt", "$R/R13/s2/k.txt" ], 'f and k are where they were');
  is(rows()->{"$R/R13/s2/k.txt"}{nodeid}, $x->{k}, 'the mirror agrees');
  ok(!grep({ m{^\Q$R/R13/\E.*~tmp~} } keys %tree), 'no temporary name is left');
}
# refused in step 3 (two movers want one name: one loses), inside the directory a replace displaces
{
  my $x = mk(D => { parentId => $home, name => 'R14' }, f => { parentId => '#D', name => 'f.txt', blobId => 'f-y' },
             s => { parentId => '#D', name => 's2' }, k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' },
             g => { parentId => '#s', name => 'g.txt', blobId => 'f-x' });
  $set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
             update => { $x->{f} => { name => 's2' }, $x->{k} => { parentId => $x->{D}, name => 'x.txt' },
                         $x->{g} => { parentId => $x->{D}, name => 'x.txt' } })->[1];
  my ($loser) = grep { ($set->{notUpdated}{$_}{type} // '') eq 'alreadyExists' } @$x{qw(k g)};
  ok($loser, 'one of the two movers loses the name') or diag explain $set;
  my ($winner) = grep { $_ ne ($loser // '') } @$x{qw(k g)};
  ok(exists $set->{updated}{$winner}, 'the other moves out') or diag explain $set;
  is($set->{notUpdated}{$x->{f}}{type}, 'nodeHasChildren', 'the replace is refused: the loser is still inside s2') or diag explain $set;
  ok(!$set->{destroyed}, 'nothing is destroyed');
  my $lname = $loser eq $x->{k} ? 'k.txt' : 'g.txt';
  is_deeply(files_under("$R/R14"), [ "$R/R14/f.txt", "$R/R14/s2/$lname", "$R/R14/x.txt" ], 'three files, the loser still in s2');
  is(rows()->{"$R/R14/s2/$lname"}{nodeid}, $loser, 'the mirror agrees');
  ok(!grep({ m{^\Q$R/R14/\E.*~tmp~} } keys %tree), 'no temporary name is left');
}
# an explicit destroy with the flag, while the child asked to move out is refused
{
  my $x = mk(D => { parentId => $home, name => 'R15' }, k => { parentId => '#D', name => 'k.txt', blobId => 'f-x' });
  $set = set(onDestroyRemoveChildren => JSON::true, destroy => [ $x->{D} ],
             update => { $x->{k} => { parentId => $home, shareWith => 'not an object' } })->[1];
  is($set->{notUpdated}{$x->{k}}{type}, 'invalidProperties', 'the move out is refused') or diag explain $set;
  is($set->{notDestroyed}{$x->{D}}{type}, 'nodeHasChildren', 'so the destroy is refused, flag or no flag') or diag explain $set;
  ok(!$set->{destroyed} && $tree{"$R/R15/k.txt"}, 'k is still there');
  is(rows()->{"$R/R15/k.txt"}{nodeid}, $x->{k}, 'the mirror agrees');
  # ... and the same for a rename, which is a move too
  $set = set(onDestroyRemoveChildren => JSON::true, destroy => [ $x->{D} ],
             update => { $x->{k} => { name => '' } })->[1];
  is($set->{notUpdated}{$x->{k}}{type}, 'invalidProperties', 'the rename is refused') or diag explain $set;
  is($set->{notDestroyed}{$x->{D}}{type}, 'nodeHasChildren', 'and so is the destroy over it') or diag explain $set;
  ok(!$set->{destroyed} && $tree{"$R/R15/k.txt"}, 'k is still there');
  # a rename that succeeds inside a directory destroyed with the flag: the client asked for both
  $set = set(onDestroyRemoveChildren => JSON::true, destroy => [ $x->{D} ], update => { $x->{k} => { name => 'k2.txt' } })->[1];
  is_deeply([ sort @{ $set->{destroyed} || [] } ], [ sort @$x{qw(D k)} ], 'both go when the rename lands inside the destroyed directory')
    or diag explain $set;
}
# a file holder whose own move away was refused is not overwritten by a replace
{
  my $x = mk(D => { parentId => $home, name => 'R16' }, a => { parentId => '#D', name => 'a.txt', blobId => 'f-y' },
             b => { parentId => '#D', name => 'b.txt', blobId => 'f-x' });
  @log = ();
  $set = set(onExists => 'replace', update => { $x->{a} => { name => 'b.txt' }, $x->{b} => { name => 'c.txt', shareWith => 'not an object' } })->[1];
  is($set->{notUpdated}{$x->{b}}{type}, 'invalidProperties', 'b\'s move away is refused') or diag explain $set;
  is_deeply($set->{notUpdated}{$x->{a}}, { type => 'alreadyExists', existingId => $x->{b} }, 'so a may not replace it') or diag explain $set;
  ok(!$set->{destroyed} && !grep({ /files_move|files_delete/ } @log), 'nothing moved or deleted');
  is(content("$R/R16/a.txt") . ' ' . content("$R/R16/b.txt"), '7:text/x-y 8:text/plain', 'both files as they were');
}
# a directory holder whose own move was refused is not replaced (nor its child taken)
{
  my $x = mk(D => { parentId => $home, name => 'R17' }, f => { parentId => '#D', name => 'f.txt', blobId => 'f-y' },
             s => { parentId => '#D', name => 's2' }, k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' });
  $set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
             update => { $x->{f} => { name => 's2' }, $x->{s} => { parentId => $home, shareWith => 'not an object' } })->[1];
  is($set->{notUpdated}{$x->{s}}{type}, 'invalidProperties', 's2\'s move is refused') or diag explain $set;
  is_deeply($set->{notUpdated}{$x->{f}}, { type => 'alreadyExists', existingId => $x->{s} }, 'so f may not replace it') or diag explain $set;
  ok(!$set->{destroyed}, 'nothing is destroyed');
  is_deeply(files_under("$R/R17"), [ "$R/R17/f.txt", "$R/R17/s2/k.txt" ], 'f and k are where they were');
}
# a create with onExists replace at the name of a directory a mover leaves:
# late, so it replaces the directory once the mover has left (R6) ...
{
  my $x = mk(D => { parentId => $home, name => 'R18' }, s => { parentId => '#D', name => 's2' },
             k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' });
  $set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
             create => { n => { parentId => $x->{D}, name => 's2', blobId => 'f-y' } },
             update => { $x->{k} => { parentId => $x->{D} } })->[1];
  ok(exists $set->{updated}{$x->{k}}, 'k moves out first') or diag explain $set;
  ok($set->{created}{n}, 'then the create replaces the directory') or diag explain $set;
  is_deeply($set->{destroyed}, [ $x->{s} ], 'which is destroyed, alone');
  is_deeply(files_under("$R/R18"), [ "$R/R18/k.txt", "$R/R18/s2" ], 'k survives beside the new file');
  is(rows()->{"$R/R18/k.txt"}{nodeid}, $x->{k}, 'the mirror agrees');
  # ... and never takes a mover whose move was refused
  $x = mk(s => { parentId => $x->{D}, name => 's3' }, k => { parentId => '#s', name => 'k.txt', blobId => 'f-x' });
  $set = set(onExists => 'replace', onDestroyRemoveChildren => JSON::true,
             create => { n => { parentId => rows()->{"$R/R18"}{nodeid}, name => 's3', blobId => 'f-y' } },
             update => { $x->{k} => { parentId => $home, shareWith => 'not an object' } })->[1];
  is($set->{notUpdated}{$x->{k}}{type}, 'invalidProperties', 'k\'s move is refused') or diag explain $set;
  is($set->{notCreated}{n}{type}, 'nodeHasChildren', 'so the create may not replace the directory over it') or diag explain $set;
  ok(!$set->{destroyed} && $tree{"$R/R18/s3/k.txt"} && $tree{"$R/R18/s3"}{isCollection}, 'k and s3 are still there');
  # a create at the name of a file whose own move was refused
  $set = set(onExists => 'replace', create => { n => { parentId => $x->{s}, name => 'k.txt', blobId => 'f-y' } },
             update => { $x->{k} => { name => 'z.txt', shareWith => 'not an object' } })->[1];
  is($set->{notUpdated}{$x->{k}}{type}, 'invalidProperties', 'k\'s rename is refused') or diag explain $set;
  is_deeply([ @{ $set->{notCreated}{n} }{qw(type existingId)} ], [ 'alreadyExists', $x->{k} ], 'so the create may not overwrite it') or diag explain $set;
  is(content("$R/R18/s3/k.txt"), '8:text/plain', 'k keeps its content');
  ok(!$set->{destroyed}, 'nothing is destroyed');
}

# --- sharing: shareWith over RFC 3744 ACLs (Task 10)
{
  features(acl => 1, principalBase => '/dav/principals/user/');
  %principal = map { ("/dav/principals/user/$_/" => 1) } qw(u user2 user3);
  my $t = JSON::true; my $f = JSON::false;
  my %none = map { ($_ => $f) } qw(mayRead mayAddChildren mayRename mayDelete mayModifyContent mayShare);
  my $x = mk(S => { parentId => $home, name => 'S1' }, k => { parentId => '#S', name => 'k.txt', blobId => 'f-x' },
             T => { parentId => $home, name => 'S2' });
  my $obj = get($x->{S})->{$x->{S}};
  ok($obj->{myRights}{mayShare}, 'a directory on an ACL server: mayShare');
  is($obj->{shareWith}, undef, 'shared with nobody: null');
  ok(!get($x->{k})->{$x->{k}}{myRights}{mayShare}, 'a file: never mayShare (spec "Sharing")');

  # set it
  my ($st0) = $api->api_FileNode_get({ accountId => $db->accountid(), ids => [] });
  @acl_reqs = ();
  $set = set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  ok(exists $set->{updated}{$x->{S}}, 'shareWith set') or diag explain $set;
  is(scalar @acl_reqs, 1, 'one ACL request');
  is_deeply($acl_reqs[0][1], [ $SELF_ACE, { principal => '/dav/principals/user/user2/', grant => ['read'], deny => [] } ],
            'it keeps the self ACE and grants user2 read') or diag explain \@acl_reqs;
  is_deeply(get($x->{S})->{$x->{S}}{shareWith}, { user2 => { %none, mayRead => $t } }, 'FileNode/get reads it back');
  my ($ch) = $api->api_FileNode_changes({ accountId => $db->accountid(), sinceState => $st0->[1]{state} });
  is_deeply($ch->[1]{updated}, [ $x->{S} ], 'FileNode/changes reports the node') or diag explain $ch;
  my $state1 = $ch->[1]{newState};

  # the same value again: nothing to do (stripped as unchanged)
  @acl_reqs = ();
  $set = set(update => { $x->{S} => { shareWith => { user2 => { %none, mayRead => $t } } } })->[1];
  ok(exists $set->{updated}{$x->{S}} && !@acl_reqs, 'the current value: no request');

  # patch paths (RFC 8620 S5.3)
  $set = set(update => { $x->{S} => { 'shareWith/user3' => { mayRead => $t, mayAddChildren => $t }, 'shareWith/user2/mayShare' => $t } })->[1];
  ok(exists $set->{updated}{$x->{S}}, 'patched') or diag explain $set;
  is_deeply(get($x->{S})->{$x->{S}}{shareWith},
            { user2 => { %none, mayRead => $t, mayShare => $t }, user3 => { %none, mayRead => $t, mayAddChildren => $t } }, 'both paths applied');
  $set = set(update => { $x->{S} => { 'shareWith/user3' => undef } })->[1];
  is_deeply([ keys %{ get($x->{S})->{$x->{S}}{shareWith} } ], ['user2'], 'a null path removes a user');
  $set = set(update => { $x->{S} => { 'shareWith/nobody/mayRead' => $t } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'invalidPatch', 'a path below a user who is not there');
  $set = set(update => { $x->{S} => { shareWith => {}, 'shareWith/user2' => undef } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'invalidPatch', 'shareWith and a path below it');

  # bad values: invalidProperties, and nothing sent
  @acl_reqs = ();
  for my $bad ('nope', [], { user2 => 1 }, { user2 => { mayRead => 1 } }, { user2 => { mayFly => $t } },
               { 'a/b' => { mayRead => $t } }, { qq{a"b<c} => { mayRead => $t } }, { '..' => { mayRead => $t } }) {
    $set = set(update => { $x->{S} => { shareWith => $bad } })->[1];
    is_deeply([ @{ $set->{notUpdated}{$x->{S}} || {} }{qw(type properties)} ], [ 'invalidProperties', ['shareWith'] ],
              'invalid: ' . JSON->new->allow_nonref->canonical->encode($bad)) or diag explain $set;
  }
  $set = set(update => { $x->{S} => { 'shareWith/a~1b' => { mayRead => $t } } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'invalidProperties', 'a "/" smuggled in through ~1');
  $set = set(update => { $x->{S} => { shareWith => { u => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'invalidProperties', 'the owner cannot be a sharee');
  is(scalar @acl_reqs, 0, 'none of them reached the server') or diag explain \@acl_reqs;

  # rights: a file, and a directory without write-acl
  $set = set(update => { $x->{k} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{k}}{type}, 'forbidden', 'a file: forbidden (no mayShare)');
  $tree{"$R/S2"}{privileges} = [qw(read write bind unbind write-content)];
  $db->sync_files();
  ok(!get($x->{T})->{$x->{T}}{myRights}{mayShare}, 'no write-acl: no mayShare');
  $set = set(update => { $x->{T} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{T}}{type}, 'forbidden', 'so setting it is forbidden');
  is(scalar @acl_reqs, 0, 'and nothing was sent');
  # ... and a node the caller may not share reads as null, whatever its ACL
  $acl{"$R/S2"} = [ $SELF_ACE, { principal => '/dav/principals/user/user2/', grant => ['read'], deny => [] } ];
  $db->sync_files();
  is(get($x->{T})->{$x->{T}}{shareWith}, undef, 'shareWith is null without mayShare');
  delete $tree{"$R/S2"}{privileges};

  # null clears
  $set = set(update => { $x->{S} => { shareWith => undef } })->[1];
  ok(exists $set->{updated}{$x->{S}}, 'null') or diag explain $set;
  is(get($x->{S})->{$x->{S}}{shareWith}, undef, 'clears it');
  is_deeply($acl{"$R/S1"}, [ $SELF_ACE ], 'only the self ACE is left');

  # every ACE that is not a user's sharing survives a rewrite
  my @other = ({ principal => '/dav/principals/user/user3/', invert => 0, grant => [], deny => ['write'], inherited => 0, protected => 0 },
               { principal => '/dav/principals/group/g/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 },
               { principal => 'property', property => '{DAV:}owner', invert => 0, grant => ['read-acl'], deny => [], inherited => 0, protected => 1 });
  $acl{"$R/S1"} = [ @other, $SELF_ACE ];
  $principal{'/dav/principals/group/g/'} = 1;
  $set = set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  is_deeply([ map { $_->{principal} } @{ $acl_reqs[-1][1] } ],
            [ '/dav/principals/user/user3/', '/dav/principals/group/g/', 'property', 'self', '/dav/principals/user/user2/' ],
            'the deny, the group, the protected and the self ACEs are sent back as they were');

  # Cyrus: it lists its admin, which is no principal, and will not take it back
  $acl{"$R/S1"} = [ $SELF_ACE, { principal => '/dav/principals/user/admin/', invert => 0, grant => ['all'], deny => [], inherited => 0, protected => 0 } ];
  $db->sync_files();
  is(get($x->{S})->{$x->{S}}{shareWith}, undef, 'the admin ACE is not shown as sharing');
  # nothing is dropped unless the operator allows it: serverFail, ACL untouched
  my $before = JSON->new->canonical->encode($acl{"$R/S1"});
  @acl_reqs = ();
  $set = set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'serverFail', 'recognized-principal for a listed ACE: serverFail') or diag explain $set;
  like($set->{notUpdated}{$x->{S}}{description}, qr{/dav/principals/user/admin/}, 'naming the principal');
  is(scalar @acl_reqs, 1, 'no second request');
  is(JSON->new->canonical->encode($acl{"$R/S1"}), $before, 'the ACL is unchanged');
  {
    # an allowlisted principal is dropped, with a warning
    local $ENV{JMAP_FILES_DROPPABLE_PRINCIPALS} = ' svc-x , admin ';
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    @acl_reqs = ();
    $set = set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
    ok(exists $set->{updated}{$x->{S}}, 'allowlisted: dropped and retried') or diag explain $set;
    is(scalar @acl_reqs, 2, 'two requests');
    ok(!grep({ $_->{principal} =~ /admin/ } @{ $acl_reqs[1][1] }), 'the second without the admin');
    ok((grep { m{dropping the ACE for /dav/principals/user/admin/} } @w), 'and the drop is warned about') or diag explain \@w;
    # ... but an unknown principal that is not on the list still stops it
    $acl{"$R/S1"} = [ $SELF_ACE, { principal => '/dav/principals/user/svc/', invert => 0, grant => ['read'], deny => [], deny => [], inherited => 0, protected => 0 },
                      { principal => '/dav/principals/user/admin/', invert => 0, grant => ['all'], deny => [], inherited => 0, protected => 0 } ];
    $before = JSON->new->canonical->encode($acl{"$R/S1"});
    $set = set(update => { $x->{S} => { shareWith => { user3 => { mayRead => $t } } } })->[1];
    is($set->{notUpdated}{$x->{S}}{type}, 'serverFail', 'an unknown principal not on the list: serverFail');
    like($set->{notUpdated}{$x->{S}}{description}, qr{/user/svc/}, 'naming it');
    unlike($set->{notUpdated}{$x->{S}}{description}, qr{/user/admin/}, 'and only it');
    is(JSON->new->canonical->encode($acl{"$R/S1"}), $before, 'the ACL is unchanged');
    $acl{"$R/S1"} = [ $SELF_ACE ];
    set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t } } } });
  }
  $set = set(update => { $x->{S} => { shareWith => { user9 => { mayRead => $t } } } })->[1];
  is_deeply([ @{ $set->{notUpdated}{$x->{S}} }{qw(type properties)} ], [ 'invalidProperties', ['shareWith'] ], 'no such user');
  like($set->{notUpdated}{$x->{S}}{description}, qr/user9/, 'named');

  # the server's privilege tree: write-acl abstract under its admin; bind holds write-content
  my $CY = '{http://cyrusimap.org/ns/}';
  $acl_tree = { all => { parent => undef, abstract => 0 }, read => { parent => 'all', abstract => 0 },
                write => { parent => 'all', abstract => 0 }, bind => { parent => 'write', abstract => 0 },
                'write-content' => { parent => 'bind', abstract => 0 }, unbind => { parent => 'write', abstract => 0 },
                "${CY}admin" => { parent => 'all', abstract => 0 }, 'write-acl' => { parent => "${CY}admin", abstract => 1 } };
  $set = set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t, mayShare => $t, mayAddChildren => $t } } } })->[1];
  is_deeply($acl_reqs[-1][1][-1]{grant}, [ 'bind', 'read', "${CY}admin" ], 'mayShare is granted as the admin privilege');
  is_deeply($set->{updated}{$x->{S}}{shareWith},
            { user2 => { %none, mayRead => $t, mayShare => $t, mayAddChildren => $t, mayModifyContent => $t } },
            'the server granted more than asked: updated says what it is') or diag explain $set;
  undef $acl_tree;

  # a refused ACL after a move: the move stays, the item is serverFail
  $acl_answer = sub { return { status => 403, error => 'need-privileges' } };
  $set = set(update => { $x->{S} => { name => 'S1b', shareWith => { user3 => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'serverFail', 'move done, ACL refused: serverFail') or diag explain $set;
  ok($tree{"$R/S1b"} && !$tree{"$R/S1"}, 'the move was made');
  is(get($x->{S})->{$x->{S}}{name}, 'S1b', 'and the mirror has it');
  $set = set(update => { $x->{S} => { shareWith => { user3 => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{S}}{type}, 'forbidden', 'shareWith alone, refused: forbidden');
  undef $acl_answer;

  # behind the proxy's back: an ACL change shows up on the next sync
  $db->sync_files();   # (the fake, like Cyrus, gave k.txt a new ETag when S1 moved)
  my ($st2) = $api->api_FileNode_get({ accountId => $db->accountid(), ids => [] });
  $acl{"$R/S2"} = [ $SELF_ACE, { principal => '/dav/principals/user/user3/', invert => 0, grant => ['read', 'write-acl'], deny => [], inherited => 0, protected => 0 } ];
  $db->sync_files();
  ($ch) = $api->api_FileNode_changes({ accountId => $db->accountid(), sinceState => $st2->[1]{state} });
  is_deeply($ch->[1]{updated}, [ $x->{T} ], 'an ACL changed elsewhere is a change') or diag explain $ch;
  is_deeply(get($x->{T})->{$x->{T}}{shareWith}, { user3 => { %none, mayRead => $t, mayShare => $t } }, 'and reads back');

  # create with shareWith
  $set = set(create => { n => { parentId => $home, name => 'S3', shareWith => { user2 => { mayRead => $t } } },
                         nf => { parentId => $home, name => 'S3.txt', blobId => 'f-x', shareWith => { user2 => { mayRead => $t } } } })->[1];
  ok($set->{created}{n}, 'a directory is created shared') or diag explain $set;
  is_deeply(get($set->{created}{n}{id})->{ $set->{created}{n}{id} }{shareWith}, { user2 => { %none, mayRead => $t } }, 'and is');
  is_deeply([ @{ $set->{notCreated}{nf} }{qw(type properties)} ], [ 'invalidProperties', ['shareWith'] ], 'a file is not');
  ok(!$tree{"$R/S3.txt"}, 'and is not created');

  # no ACL support: setting is invalidProperties, reading is null
  features();
  is(get($x->{T})->{$x->{T}}{shareWith}, undef, 'no ACLs: null');
  $set = set(update => { $x->{T} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  is_deeply([ @{ $set->{notUpdated}{$x->{T}} }{qw(type properties)} ], [ 'invalidProperties', ['shareWith'] ], 'no ACLs: invalidProperties');
}

# --- sharing, fix round 1
{
  my $t = JSON::true; my $f = JSON::false;
  my %none = map { ($_ => $f) } qw(mayRead mayAddChildren mayRename mayDelete mayModifyContent mayShare);
  %principal = map { ("/dav/principals/user/$_/" => 1) } qw(u user2 user3);
  undef $acl_answer; undef $acl_tree;

  # I2: a feature set without principalBase learns it from the owner
  features(acl => 1);
  my $x = mk(P => { parentId => $home, name => 'P1' });
  $acl{"$R/P1"} = [ $SELF_ACE, { principal => '/dav/principals/staff/', href => '/dav/principals/staff/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 } ];
  $principal{'/dav/principals/staff/'} = 1;
  $db->sync_files();
  is(get($x->{P})->{$x->{P}}{shareWith}, undef, 'no principalBase: a group beside the users is nobody\'s sharing');
  $set = set(update => { $x->{P} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  ok(exists $set->{updated}{$x->{P}}, 'set without a known base') or diag explain $set;
  is($acl_reqs[-1][1][-1]{principal}, '/dav/principals/user/user2/', 'the new ACE goes below the owner\'s parent');
  ok((grep { $_->{principal} eq '/dav/principals/staff/' } @{ $acl_reqs[-1][1] }), 'the group ACE is kept');
  is($acl_reqs[-1][1][1]{href}, '/dav/principals/staff/', 'with the href it came with (M5)');
  $db->begin(); my $fj = decode_json($db->dgetfield('iserver', {}, 'webdavFeatures')); $db->commit();
  is($fj->{principalBase}, '/dav/principals/user/', 'principalBase is learnt and kept');
  is_deeply(get($x->{P})->{$x->{P}}{shareWith}, { user2 => { %none, mayRead => $t } }, 'and the read side agrees');

  # I1: a 404 remembered for a principal that appears later does not hide it
  $acl{"$R/P1"} = [ $SELF_ACE, { principal => '/dav/principals/user/user5/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 } ];
  $db->sync_files();
  is(get($x->{P})->{$x->{P}}{shareWith}, undef, 'user5 answers 404: not shown');
  $principal{'/dav/principals/user/user5/'} = 1;   # user5 logs in for the first time
  $set = set(update => { $x->{P} => { shareWith => { user5 => { mayRead => $t, mayAddChildren => $t } } } })->[1];
  ok(exists $set->{updated}{$x->{P}}, 'user5 shared with') or diag explain $set;
  is(scalar(grep { $_->{principal} =~ m{/user5/} } @{ $acl{"$R/P1"} }), 1, 'one ACE for user5, not the old one kept beside a new one')
    or diag explain $acl{"$R/P1"};
  is_deeply(get($x->{P})->{$x->{P}}{shareWith}, { user5 => { %none, mayRead => $t, mayAddChildren => $t } }, 'and it reads back');
  # ... and on the read side the 404 is only remembered for a while
  $acl{"$R/P1"} = [ $SELF_ACE, { principal => '/dav/principals/user/user6/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 } ];
  $db->sync_files();
  is(get($x->{P})->{$x->{P}}{shareWith}, undef, 'user6 answers 404: not shown');
  $principal{'/dav/principals/user/user6/'} = 1;
  $db->{_files_principal}{'/dav/principals/user/user6/'}{until} = time() - 1;   # the minute passes
  $db->sync_files();
  ok(get($x->{P})->{$x->{P}}{shareWith}{user6}, 'once the remembered 404 expires, user6 shows');

  # M1: overlapping patch paths
  $set = set(update => { $x->{P} => { 'shareWith/user6' => { mayRead => $t }, 'shareWith/user6/mayShare' => $t } })->[1];
  is($set->{notUpdated}{$x->{P}}{type}, 'invalidPatch', 'a path and a path below it: invalidPatch');

  # M3: the owner as a sharee never reaches the server -- not even a PROPFIND
  @log = ();
  $set = set(update => { $x->{P} => { shareWith => { u => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{P}}{type}, 'invalidProperties', 'the owner as a sharee');
  is_deeply(\@log, [], 'no request at all') or diag explain \@log;
  @log = ();
  $set = set(create => { o => { parentId => $home, name => 'P0', shareWith => { u => { mayRead => $t } } } })->[1];
  is($set->{notCreated}{o}{type}, 'invalidProperties', 'nor on create');
  is_deeply(\@log, [], 'with no request either') or diag explain \@log;

  # M2: a caller without mayShare learns nothing about the sharees
  $tree{"$R/P1"}{privileges} = [qw(read write bind unbind write-content)];
  $db->sync_files();
  my @e = map { set(update => { $x->{P} => { $_ => $t } })->[1]{notUpdated}{$x->{P}} } 'shareWith/user6/mayShare', 'shareWith/nobody/mayShare';
  is_deeply($e[0], $e[1], 'the same answer for a sharee and for a stranger');
  is($e[0]{type}, 'forbidden', 'forbidden');
  delete $tree{"$R/P1"}{privileges};
  $db->sync_files();

  # M4: kept ACEs that come back changed are warned about
  $acl{"$R/P1"} = [ $SELF_ACE, { principal => '/dav/principals/staff/', href => '/dav/principals/staff/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 } ];
  $acl_answer = sub { my ($d, $aces) = @_; $acl{$d} = [ map { +{ %$_, ($_->{principal} =~ /staff/ ? (grant => ['all']) : ()) } } @$aces ]; return { status => 200 } };
  my @w;
  { local $SIG{__WARN__} = sub { push @w, @_ }; $set = set(update => { $x->{P} => { shareWith => { user2 => { mayRead => $t } } } })->[1] }
  ok(exists $set->{updated}{$x->{P}}, 'set');
  ok((grep { /kept came back changed/ } @w), 'a kept ACE that came back changed is warned about') or diag explain \@w;
  undef $acl_answer;

  # PROPAGATION: a share reaches every directory below, touching only the users that changed
  $x = mk(A => { parentId => $home, name => 'PA' }, B => { parentId => '#A', name => 'b' }, C => { parentId => '#B', name => 'c' },
          f => { parentId => '#B', name => 'f.txt', blobId => 'f-x' });
  my $own3 = { principal => '/dav/principals/user/user3/', invert => 0, grant => ['read', 'bind'], deny => [], inherited => 0, protected => 0 };
  my $grp  = { principal => '/dav/principals/staff/', href => '/dav/principals/staff/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 };
  $acl{"$R/PA/b"} = [ $SELF_ACE, $grp, $own3 ];
  $db->sync_files();
  my ($st) = $api->api_FileNode_get({ accountId => $db->accountid(), ids => [] });
  @acl_reqs = ();
  $set = set(update => { $x->{A} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  ok(exists $set->{updated}{$x->{A}}, 'shared') or diag explain $set;
  is_deeply([ map { $_->[0] } @acl_reqs ], [ "$R/PA", "$R/PA/b", "$R/PA/b/c" ], 'the node, then each directory below, parents first');
  is_deeply([ map { $_->{principal} } @{ $acl{"$R/PA/b"} } ], [ 'self', '/dav/principals/staff/', '/dav/principals/user/user3/', '/dav/principals/user/user2/' ],
            'below: user2 added, every other ACE kept') or diag explain $acl{"$R/PA/b"};
  ok((grep { $_->{principal} =~ m{/user2/} } @{ $acl{"$R/PA/b/c"} }), 'and two levels down');
  my ($ch) = $api->api_FileNode_changes({ accountId => $db->accountid(), sinceState => $st->[1]{state} });
  is_deeply([ sort @{ $ch->[1]{updated} } ], [ sort @$x{qw(A B C)} ], 'FileNode/changes reports the descendants') or diag explain $ch;
  is_deeply(get($x->{C})->{$x->{C}}{shareWith}, { user2 => { %none, mayRead => $t } }, 'whose mirror has the sharing');
  ok(get($x->{B})->{$x->{B}}{shareWith}{user3}, 'and keeps what was its own');
  $db->sync_files();
  ($ch) = $api->api_FileNode_changes({ accountId => $db->accountid(), sinceState => $ch->[1]{newState} });
  is_deeply($ch->[1]{updated}, [], 'the next sync agrees with the mirror') or diag explain $ch;

  # a change: only the users that changed go to the descendants
  @acl_reqs = ();
  $set = set(update => { $x->{A} => { 'shareWith/user2/mayAddChildren' => $t } })->[1];
  is(scalar @acl_reqs, 3, 'one request per directory');
  is_deeply([ map { join ',', @{ $_->{grant} } } grep { $_->{principal} =~ m{/user[23]/} } @{ $acl{"$R/PA/b"} } ],
            [ 'read,bind', 'bind,read' ], 'user3\'s own grant below is untouched; user2\'s follows') or diag explain $acl{"$R/PA/b"};
  # nothing changed for anyone: nothing below is touched
  @acl_reqs = ();
  $set = set(update => { $x->{A} => { 'shareWith/user2/mayModifyContent' => $f } })->[1];
  is(scalar @acl_reqs, 0, 'no change for anyone: no request at all (a no-op rewrite still costs rights on Cyrus)');
  # unshare
  $set = set(update => { $x->{A} => { shareWith => undef } })->[1];
  ok(!(grep { $_->{principal} =~ m{/user2/} } map { @{ $acl{$_} || [] } } "$R/PA", "$R/PA/b", "$R/PA/b/c"), 'unshared everywhere');
  ok(get($x->{B})->{$x->{B}}{shareWith}{user3} && !get($x->{C})->{$x->{C}}{shareWith}, 'the mirror follows');

  # a descendant that refuses: the node still succeeds; the descendant's mirror shows the server
  $acl_answer = sub { return $_[0] eq "$R/PA/b" ? { status => 403, error => 'need-privileges' } : undef };
  @w = ();
  { local $SIG{__WARN__} = sub { push @w, @_ }; $set = set(update => { $x->{A} => { shareWith => { user2 => { mayRead => $t } } } })->[1] }
  ok(exists $set->{updated}{$x->{A}}, 'the node is shared') or diag explain $set;
  ok((grep { m{PA/b/: ACL: HTTP 403} } @w), 'the refusal below is warned about') or diag explain \@w;
  ok(!get($x->{B})->{$x->{B}}{shareWith}{user2}, 'b\'s mirror: as the server has it (no user2)');
  ok(get($x->{C})->{$x->{C}}{shareWith}{user2}, 'c still got it');
  undef $acl_answer;
  $set = set(update => { $x->{A} => { shareWith => undef } })->[1];

  # a server that inherits: nothing is copied below
  $inherits = 1;
  @acl_reqs = ();
  $set = set(update => { $x->{A} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  ok(exists $set->{updated}{$x->{A}}, 'shared on an inheriting server');
  is_deeply([ map { $_->[0] } @acl_reqs ], [ "$R/PA" ], 'the descendants show it inherited: no request below');
  $inherits = 0;
  features();
}

# --- sharing, fix round 2
{
  my $t = JSON::true; my $f = JSON::false;
  features(acl => 1, principalBase => '/dav/principals/user/');
  %principal = map { ("/dav/principals/user/$_/" => 1) } qw(u user2 user3);
  undef $acl_answer; $inherits = 0;
  my $x = mk(Sh => { parentId => $home, name => 'Q-shared' }, Sh2 => { parentId => $home, name => 'Q-shared2' },
             U => { parentId => $home, name => 'Q-plain' }, M => { parentId => '#U', name => 'm' },
             N => { parentId => '#M', name => 'n' }, g => { parentId => '#N', name => 'g.txt', blobId => 'f-x' });
  set(update => { $x->{Sh} => { shareWith => { user2 => { mayRead => $t } } }, $x->{Sh2} => { shareWith => { user2 => { mayRead => $t } } } });
  my $own3 = { principal => '/dav/principals/user/user3/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 };
  $acl{"$R/Q-plain/m"} = [ $SELF_ACE, $own3 ];
  $db->sync_files();
  my $users = sub { [ sort map { m{/user/([^/]+)/} ? $1 : () } map { $_->{principal} } @{ $acl{ $_[0] } || [] } ] };

  # moving a directory into a shared one shares it, and everything below
  my ($st) = $api->api_FileNode_get({ accountId => $db->accountid(), ids => [] });
  $set = set(update => { $x->{M} => { parentId => $x->{Sh} } })->[1];
  ok(exists $set->{updated}{$x->{M}}, 'moved in') or diag explain $set;
  is_deeply($users->("$R/Q-shared/m"), [ qw(user2 user3) ], 'the moved directory gets the new parent\'s sharee, and keeps its own');
  is_deeply($users->("$R/Q-shared/m/n"), ['user2'], 'and so does the one below');
  my ($ch) = $api->api_FileNode_changes({ accountId => $db->accountid(), sinceState => $st->[1]{state} });
  ok((grep { $_ eq $x->{N} } @{ $ch->[1]{updated} }), 'FileNode/changes reports the directory below') or diag explain $ch;
  ok(get($x->{N})->{$x->{N}}{shareWith}{user2}, 'whose mirror has it');

  # between two parents that share alike: nothing to do
  @acl_reqs = ();
  $set = set(update => { $x->{M} => { parentId => $x->{Sh2} } })->[1];
  ok(exists $set->{updated}{$x->{M}}, 'moved across');
  is(scalar @acl_reqs, 0, 'parents sharing alike: no ACL request');

  # moving out removes only what came from the old parent
  $set = set(update => { $x->{M} => { parentId => $x->{U} } })->[1];
  ok(exists $set->{updated}{$x->{M}}, 'moved out') or diag explain $set;
  is_deeply($users->("$R/Q-plain/m"), ['user3'], 'the old parent\'s sharee goes; its own stays');
  is_deeply($users->("$R/Q-plain/m/n"), [], 'and below');
  ok(!get($x->{N})->{$x->{N}}{shareWith}, 'the mirror follows');

  # a refusal never undoes the move
  $acl_answer = sub { return $_[0] eq "$R/Q-shared/m" ? { status => 403, error => 'need-privileges' } : undef };
  my @w;
  { local $SIG{__WARN__} = sub { push @w, @_ }; $set = set(update => { $x->{M} => { parentId => $x->{Sh} } })->[1] }
  ok(exists $set->{updated}{$x->{M}} && $tree{"$R/Q-shared/m"}, 'the move stands') or diag explain $set;
  ok((grep { m{Q-shared/m/: ACL: HTTP 403} } @w), 'the refusal is warned about') or diag explain \@w;
  ok(!get($x->{M})->{$x->{M}}{shareWith}{user2}, 'and its mirror shows the server');
  ok(get($x->{N})->{$x->{N}}{shareWith}{user2}, 'the one below still got it');
  undef $acl_answer;
  set(update => { $x->{M} => { parentId => $x->{U} } });

  # a server that inherits: nothing is carried
  $inherits = 1;
  @acl_reqs = ();
  $set = set(update => { $x->{M} => { parentId => $x->{Sh} } })->[1];
  ok(exists $set->{updated}{$x->{M}}, 'moved in, on an inheriting server');
  is(scalar @acl_reqs, 0, 'no ACL request');
  $inherits = 0;
  set(update => { $x->{M} => { parentId => $x->{U} } });

  # propagation retries with the remembered answers, and drops nothing unlisted
  my $y = mk(S => { parentId => $x->{Sh}, name => 'sub' });
  $acl{"$R/Q-shared/sub"} = [ $SELF_ACE, { principal => '/dav/principals/user/svc/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 } ];
  my $before = JSON->new->canonical->encode($acl{"$R/Q-shared/sub"});
  @w = ();
  { local $SIG{__WARN__} = sub { push @w, @_ }; $set = set(update => { $x->{Sh} => { shareWith => { user3 => { mayRead => $t } } } })->[1] }
  ok(exists $set->{updated}{$x->{Sh}}, 'the node itself is shared') or diag explain $set;
  is(JSON->new->canonical->encode($acl{"$R/Q-shared/sub"}), $before, 'the descendant naming an unknown principal is left as it was');
  ok((grep { m{Q-shared/sub/: the server will not take back ACEs for /dav/principals/user/svc/} } @w), 'and that is warned about') or diag explain \@w;

  # a descendant already as it should be: no request
  $acl{"$R/Q-shared/sub"} = [ $SELF_ACE ];
  set(update => { $x->{Sh} => { shareWith => undef } });
  $acl{"$R/Q-shared/sub"} = [ $SELF_ACE, { principal => '/dav/principals/user/user2/', grant => ['read'], deny => [] } ];
  @acl_reqs = ();
  set(update => { $x->{Sh} => { shareWith => { user2 => { mayRead => $t } } } });
  is_deeply([ map { $_->[0] } @acl_reqs ], [ "$R/Q-shared" ], 'a descendant that already has it gets no request');

  # M2: the error is the request's own
  $acl_answer = sub { die "boom on the wire\n" };
  $set = set(update => { $x->{Sh} => { shareWith => { user3 => { mayRead => $t } } } })->[1];
  like($set->{notUpdated}{$x->{Sh}}{description}, qr/ACL: boom on the wire/, 'a failed request reports its own error');
  undef $acl_answer;
  features();
}

# --- sharing, fix round 3
{
  my $t = JSON::true;
  features(acl => 1, principalBase => '/dav/principals/user/');
  %principal = map { ("/dav/principals/user/$_/" => 1) } qw(u user2 user3);
  undef $acl_answer; $inherits = 0;
  my $users = sub { [ sort map { m{/user/([^/]+)/} ? $1 : () } map { $_->{principal} } @{ $acl{ $_[0] } || [] } ] };
  # Two moves in one call: P out of shared S, and C (inside P) out to Q.
  # C's sharing came from P before the call, whatever P's own carry does
  # first.  Ids are time-ordered, so the child's id sorts first only when
  # it was made first (and moved into P afterwards).
  for my $childfirst (0, 1) {
    my $tag = "R3$childfirst";
    my $x = mk(S => { parentId => $home, name => "${tag}S" }, U => { parentId => $home, name => "${tag}U" },
               Q => { parentId => $home, name => "${tag}Q" });
    my ($P, $C);
    if ($childfirst) {
      $C = mk(C => { parentId => $home, name => "${tag}c" })->{C};
      $P = mk(P => { parentId => $x->{S}, name => 'p' })->{P};
      set(update => { $C => { parentId => $P, name => 'c' } });
    }
    else {
      my $y = mk(P => { parentId => $x->{S}, name => 'p' }, C => { parentId => '#P', name => 'c' });
      ($P, $C) = @$y{qw(P C)};
    }
    set(update => { $x->{S} => { shareWith => { user2 => { mayRead => $t } } } });   # reaches P and C
    my $order = $C lt $P ? 'child id first' : 'parent id first';
    is($order, $childfirst ? 'child id first' : 'parent id first', "the ids sort as intended ($order)");
    ok((grep { $_ eq 'user2' } @{ $users->("$R/${tag}S/p/c") }), "C is shared through S ($order)");
    $set = set(update => { $P => { parentId => $x->{U} }, $C => { parentId => $x->{Q} } })->[1];
    ok(exists $set->{updated}{$P} && exists $set->{updated}{$C}, "both moved ($order)") or diag explain $set;
    is_deeply($users->("$R/${tag}Q/c"), [], "C has no user2 ACE ($order)") or diag explain $acl{"$R/${tag}Q/c"};
    is_deeply($users->("$R/${tag}U/p"), [], "nor P ($order)");
    ok(!get($C)->{$C}{shareWith}, "and C's mirror agrees ($order)");
  }

  # a bare allowlist name is a user principal only; an href must match exactly
  local $ENV{JMAP_FILES_DROPPABLE_PRINCIPALS} = 'admin, /dav/principals/svc/robot/';
  my $b = '/dav/principals/user/';
  ok(JMAP::ImapDB::_files_droppable('/dav/principals/user/admin/', $b), '"admin": the user principal admin');
  ok(!JMAP::ImapDB::_files_droppable('/dav/principals/group/admin/', $b), 'not a group called admin');
  ok(!JMAP::ImapDB::_files_droppable('/dav/principals/user/admin/', undef), 'nor anything when the base is unknown');
  ok(JMAP::ImapDB::_files_droppable('/dav/principals/svc/robot/', $b), 'a whole href matches exactly');
  ok(!JMAP::ImapDB::_files_droppable('/dav/principals/svc/robot/x/', $b), 'and only exactly');
  # end to end: a group "admin" stops the share
  my $x = mk(G => { parentId => $home, name => 'R3G' });
  $acl{"$R/R3G"} = [ $SELF_ACE, { principal => '/dav/principals/group/admin/', invert => 0, grant => ['read'], deny => [], inherited => 0, protected => 0 } ];
  my $before = JSON->new->canonical->encode($acl{"$R/R3G"});
  $set = set(update => { $x->{G} => { shareWith => { user2 => { mayRead => $t } } } })->[1];
  is($set->{notUpdated}{$x->{G}}{type}, 'serverFail', 'a group named admin is not dropped: serverFail');
  is(JSON->new->canonical->encode($acl{"$R/R3G"}), $before, 'and its ACL is unchanged');
  features();
}

# --- a MOVE that leaves an empty collection behind (Cyrus; moveLeavesEmpty)
{
  my $learnt = sub { $db->begin(); my $f = decode_json($db->dgetfield('iserver', {}, 'webdavFeatures')); $db->commit(); $f->{moveLeavesEmpty} };
  my $looked = sub { my $h = shift; scalar grep { $_ eq "files_prop_find $h/" || $_ eq "files_delete $h/" } @log };
  # not known yet, a server that leaves one: found on the first nested move, and tidied
  features();
  $move_leaves_shell = 1;
  my $x = mk(P => { parentId => $home, name => 'ML1' }, c => { parentId => '#P', name => 'c' });
  $set = set(update => { $x->{P} => { name => 'ML1b' } })->[1];
  ok(exists $set->{updated}{$x->{P}}, 'a nested directory renamed') or diag explain $set;
  ok(!$tree{"$R/ML1"}, 'the empty collection left at the old name is gone');
  ok($tree{"$R/ML1b/c"}, 'the moved tree is whole');
  is($learnt->(), 1, 'and the server is known to leave one');
  # known: a flat directory's move is checked too
  $x = mk(P => { parentId => $home, name => 'ML2' });
  @log = ();
  set(update => { $x->{P} => { name => 'ML2b' } });
  ok($looked->("$R/ML2"), 'a server known to leave one: every directory move is checked');
  $move_leaves_shell = 0;

  # a server that does not: once learnt, nothing extra is sent
  features();
  $x = mk(P => { parentId => $home, name => 'ML3' }, c => { parentId => '#P', name => 'c' });
  @log = ();
  set(update => { $x->{P} => { name => 'ML3b' } });
  is($learnt->(), 0, 'a nested move that leaves nothing: learnt');
  $x = mk(P => { parentId => $home, name => 'ML4' }, c => { parentId => '#P', name => 'c' });
  @log = ();
  set(update => { $x->{P} => { name => 'ML4b' } });
  is($looked->("$R/ML4"), 0, 'and from then on no PROPFIND or DELETE of the old name') or diag explain \@log;
  # not known yet: a flat directory's move tells nothing, so nothing is asked
  features();
  $x = mk(P => { parentId => $home, name => 'ML5' });
  @log = ();
  set(update => { $x->{P} => { name => 'ML5b' } });
  is($looked->("$R/ML5"), 0, 'unknown, a flat directory: no extra requests');

  # a case-only rename on a case-insensitive server: the old href is the
  # moved collection itself, and nothing is deleted
  features(moveLeavesEmpty => 1);
  $ci_server = 1;
  $x = mk(P => { parentId => $home, name => 'Foo' });
  @log = ();
  $set = set(update => { $x->{P} => { name => 'foo' } })->[1];
  ok(exists $set->{updated}{$x->{P}}, 'a case-only rename') or diag explain $set;
  ok($tree{"$R/foo"}, 'the directory is there under its new name');
  ok(!(grep { /^files_delete/ } @log), 'and nothing was deleted') or diag explain \@log;
  $ci_server = 0;
  features();
}

ok(!$db->in_transaction(), 'no transaction left open');
done_testing;
