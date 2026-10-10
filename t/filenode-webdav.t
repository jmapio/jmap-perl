#!/usr/bin/perl
# t/filenode-webdav.t -- FileNode against Cyrus #drive through the proxy.
# Needs: bin/restart-test-proxy.sh clean (IMAP mode).
use strict;
use warnings;
use Test::More;
use JSON;
use HTTP::Tiny;
use MIME::Base64;
use lib '.';
use JMAP::Sync::WebDAVTalk;
use Data::UUID::LibUUID qw(new_uuid_string);

plan skip_all => 'set CYRUS_URL and JMAP_PROXY_URL' unless $ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL};
my $user = $ENV{CYRUS_USER} || 'user1';
my $http = HTTP::Tiny->new;
my $auth = 'Basic ' . MIME::Base64::encode_base64("$user:password", '');
my @using = ('urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:filenode');
my $mgmt = ($ENV{JMAP_MGMT_URL} || 'http://localhost:8081') =~ s{/\z}{}r;

# A FileNode method only re-walks the WebDAV tree when the mirror is over 60s
# old (spec "Sync"); an explicit management-API sync always does.  Use it
# after changing the drive behind the proxy's back.
sub force_sync {
  my $res = $http->post("$mgmt/api/accounts/$user/sync");
  die "sync: HTTP $res->{status}: $res->{content}" unless $res->{success};
}

sub jmap {
  my @calls = @_;
  my $res = $http->post("$ENV{JMAP_PROXY_URL}/jmap/", {
    headers => { Authorization => $auth, 'Content-Type' => 'application/json' },
    content => encode_json({ using => \@using,
      methodCalls => [ map { [ $_->[0], { accountId => $user, %{$_->[1]} }, "c$_->[2]" ] }
                       map { [ @{$calls[$_]}, $_ ] } 0 .. $#calls ] }),
  });
  die "HTTP $res->{status}: $res->{content}" unless $res->{success};
  return [ map { $_->[1] } @{ decode_json($res->{content})->{methodResponses} } ];
}

my $dav = JMAP::Sync::WebDAVTalk->new(user => $user, password => 'x',
                                      url => "$ENV{CYRUS_URL}/dav/drive/user/$user/");
my $root = "/dav/drive/user/$user";
my $tag = 't' . lc(substr(new_uuid_string() =~ s/-//gr, 0, 8));

# session advertises the capability
my $sess = decode_json($http->get("$ENV{JMAP_PROXY_URL}/.well-known/jmap", { headers => { Authorization => $auth } })->{content});
ok($sess->{capabilities}{'urn:ietf:params:jmap:filenode'}, 'session capability');
is_deeply($sess->{capabilities}{'urn:ietf:params:jmap:filenode'}, {}, 'and it is an empty object');
my $acap = $sess->{accounts}{$user}{accountCapabilities}{'urn:ietf:params:jmap:filenode'};
is($acap->{maxSizeFileNodeName}, 255, 'account capability');

# the root (find it with FileNode/query or a full /get)
force_sync();   # whatever else changed on the drive is in the mirror before $state is taken
my ($all) = @{ jmap(['FileNode/get', { ids => undef }]) };
my @top = grep { !defined $_->{parentId} } @{$all->{list}};
is(scalar @top, 1, 'one top-level node');
my $home = $top[0];
is($home->{role}, 'home', 'root has role home');
is($home->{parentId}, undef, 'root parentId is null');
is($home->{nodeType}, 'directory', 'root is a directory');
my $state = $all->{state};

# changes made behind the proxy's back show up
$dav->Mkcol("$root/$tag");
# reconcile's weakest move tier matches size + getlastmodified, and only when
# unique across the whole drive; a fixed 1-byte payload can collide with any
# other small file another test or run wrote in the same second (the move then
# correctly becomes destroy + create).  Use a size nothing else uses.
my $onebody = 'x' x (101 + int(rand(800)));
$dav->Put("$root/$tag/one.txt", $onebody, type => 'text/plain');
force_sync();
my ($c) = @{ jmap(['FileNode/changes', { sinceState => $state }]) };
is(scalar @{$c->{created}}, 2, 'external MKCOL + PUT are two creations') or diag explain $c;
my ($g2) = @{ jmap(['FileNode/get', { ids => $c->{created} }]) };
my ($file) = grep { $_->{name} eq 'one.txt' } @{$g2->{list}};
my ($dir)  = grep { $_->{name} eq $tag } @{$g2->{list}};
is($file->{parentId}, $dir->{id}, 'parent linkage');
is($dir->{parentId}, $home->{id}, 'directory under home');
is($file->{size}, length $onebody, 'size');
is($file->{type}, 'text/plain', 'type');
is($file->{myRights}{mayModifyContent}, JSON::true, 'a Cyrus file (no privileges listed) inherits write-content from its parent');
like($file->{blobId}, qr/^d-/, 'blobId');
like($file->{id}, qr/^[LS]/, 'id prefix');
is($dir->{blobId}, undef, 'a directory has no blobId');

# an external move keeps the id (Cyrus: size + getlastmodified)
$state = $c->{newState};
$dav->Move("$root/$tag/one.txt", "$root/$tag/renamed.txt");
force_sync();
($c) = @{ jmap(['FileNode/changes', { sinceState => $state }]) };
is_deeply($c->{updated}, [ $file->{id} ], 'external move is an update of the same node, and only of it') or diag explain $c;
is_deeply($c->{created}, [], 'not a creation');
is_deeply($c->{destroyed}, [], 'nor a destruction');
my ($g3) = @{ jmap(['FileNode/get', { ids => [ $file->{id} ] }]) };
is($g3->{list}[0]{name}, 'renamed.txt', 'the node carries its new name');

# fetchParents
my ($fp) = @{ jmap(['FileNode/get', { ids => [ $file->{id} ], fetchParents => JSON::true, properties => ['name', 'parentId'] }]) };
is_deeply([ sort map { $_->{id} } @{$fp->{list}} ], [ sort $file->{id}, $dir->{id}, $home->{id} ], 'fetchParents');
is_deeply([ sort keys %{$fp->{list}[0]} ], [qw(id name parentId)], 'properties limits the output');

# notFound
my ($nf) = @{ jmap(['FileNode/get', { ids => [ 'Lnosuchnode' ] }]) };
is_deeply($nf->{notFound}, [ 'Lnosuchnode' ], 'unknown id is notFound');

# an external delete is a destruction
$state = $c->{newState};
$dav->Raw('DELETE', "$root/$tag/");
force_sync();
($c) = @{ jmap(['FileNode/changes', { sinceState => $state }]) };
is_deeply([ sort @{$c->{destroyed}} ], [ sort $file->{id}, $dir->{id} ], 'external DELETE destroys both') or diag explain $c;

# --- FileNode/set create and destroy (Task 6)
sub upload {
  my $res = $http->post("$ENV{JMAP_PROXY_URL}/upload/$user/", {
    headers => { Authorization => $auth, 'Content-Type' => 'text/plain' }, content => shift });
  die "upload: HTTP $res->{status}" unless $res->{success};
  return decode_json($res->{content});
}
sub get1 { my ($g) = @{ jmap(['FileNode/get', { ids => [ shift ] }]) }; return $g->{list}[0] }
my $blob = upload('uploaded');
my $tag2 = "$tag-set";

my ($set) = @{ jmap(['FileNode/set', { create => { top => { parentId => $home->{id}, name => $tag2 } } }]) };
my $top = $set->{created}{top};
ok($top && $top->{id}, 'directory created') or diag explain $set;
is($top->{nodeType}, 'directory', 'inferred nodeType returned');
is($top->{blobId}, undef, 'a directory has a null blobId');
is($top->{name}, undef, 'name was sent, so it is not echoed');
ok(exists $top->{created} && exists $top->{changed} && exists $top->{myRights}, 'server-set and defaulted properties returned');
is($top->{executable}, JSON::false, 'executable defaults to false');
is($top->{isSubscribed}, JSON::true, 'isSubscribed defaults to true');
is($set->{newState} ne $set->{oldState}, 1, 'the state moved');
my $s0 = $set->{newState};

($set) = @{ jmap(['FileNode/set', { create => {
  sub => { parentId => '#d', name => "caf\x{e9} [2] %#?.txt", blobId => $blob->{blobId}, type => 'text/plain' },
  d   => { parentId => $top->{id}, name => 'made dir' },
} }]) };
ok($set->{created}{d}{id} && $set->{created}{sub}{id}, 'directory and file (with a #ref parent) created') or diag explain $set;
my $l = $dav->PropFind("$root/$tag2/made dir/", 1);
ok((grep { $_->{href} eq "$root/$tag2/made dir/caf\x{e9} [2] %#?.txt" } @$l), 'on the server, escaped exactly once') or diag explain $l;
is($set->{created}{sub}{size}, 8, 'server-set size returned');
like($set->{created}{sub}{blobId}, qr/^d-/, 'and a blobId of its own');
is($dav->Get("$root/$tag2/made dir/caf\x{e9} [2] %#?.txt")->{content}, 'uploaded', 'content stored');
my $subid = $set->{created}{sub}{id};
my $madeid = $set->{created}{d}{id};
is(get1($subid)->{parentId}, $madeid, 'the #ref resolved to the new directory');
is(get1($subid)->{name}, "caf\x{e9} [2] %#?.txt", 'a non-ASCII name comes back as sent');
force_sync();
is(get1($subid)->{name}, "caf\x{e9} [2] %#?.txt", 'and a sync keeps the node (and its id)');

my ($ch) = @{ jmap(['FileNode/changes', { sinceState => $s0 }]) };
is_deeply([ sort @{$ch->{created}} ], [ sort $subid, $madeid ], '/changes sees the creations') or diag explain $ch;

($set) = @{ jmap(['FileNode/set', { create => { again => { parentId => $madeid, name => "caf\x{e9} [2] %#?.txt", blobId => $blob->{blobId} } } }]) };
is($set->{notCreated}{again}{type}, 'alreadyExists', 'name clash is alreadyExists');
is($set->{notCreated}{again}{existingId}, $subid, 'with existingId');

($set) = @{ jmap(['FileNode/set', { compareCaseInsensitively => JSON::true,
  create => { again => { parentId => $madeid, name => "CAF\x{c9} [2] %#?.TXT", blobId => $blob->{blobId} } } }]) };
is($set->{notCreated}{again}{type}, 'alreadyExists', 'compareCaseInsensitively finds the clash');

($set) = @{ jmap(['FileNode/set', { onExists => 'rename', create => { r => { parentId => $madeid, name => "caf\x{e9} [2] %#?.txt", blobId => $blob->{blobId} } } }]) };
is($set->{created}{r}{name}, "caf\x{e9} [2] %#?[2].txt", 'onExists rename returns the new name') or diag explain $set;

($set) = @{ jmap(['FileNode/set', { onExists => 'unchanged', create => { u => { parentId => $madeid, name => 'u', blobId => $blob->{blobId} } } }]) };
is($set->{type}, 'invalidArguments', 'onExists unchanged needs JMAP-CONDITIONAL: invalidArguments');
($set) = @{ jmap(['FileNode/set', { onExists => 'bogus', create => {} }]) };
is($set->{type}, 'invalidArguments', 'unknown onExists');

my $blob2 = upload('replacement');
($set) = @{ jmap(['FileNode/set', { onExists => 'replace', create => { rep => { parentId => $madeid, name => "caf\x{e9} [2] %#?.txt", blobId => $blob2->{blobId} } } }]) };
ok($set->{created}{rep}{id}, 'onExists replace creates') or diag explain $set;
isnt($set->{created}{rep}{id}, $subid, 'a new node');
ok((grep { $_ eq $subid } @{ $set->{destroyed} || [] }), 'the replaced node is listed as destroyed');
is($dav->Get("$root/$tag2/made dir/caf\x{e9} [2] %#?.txt")->{content}, 'replacement', 'new content on the server');
$subid = $set->{created}{rep}{id};

($set) = @{ jmap(['FileNode/set', { create => {
  bad   => { parentId => $madeid, name => 'a/b' },
  dot   => { parentId => $madeid, name => '..' },
  noname => { parentId => $madeid },
  nopar => { name => 'orphan' },
  sym   => { parentId => $madeid, name => 'l', target => ['x'] },
  fdir  => { parentId => $madeid, name => 'x', nodeType => 'file' },
  srv   => { parentId => $madeid, name => 'y', id => 'Lx' },
  size  => { parentId => $madeid, name => 'z', blobId => $blob->{blobId}, size => 3 },
  mt    => { parentId => $madeid, name => 'w', blobId => $blob->{blobId}, type => 'not a type' },
  role  => { parentId => $madeid, name => 'v', role => 'trash' },
  infile => { parentId => $subid, name => 'v' },
} }]) };
my %want = (bad => 'name', dot => 'name', noname => 'name', nopar => 'parentId', sym => 'nodeType',
            fdir => 'blobId', srv => 'id', size => 'size', mt => 'type', role => 'role', infile => 'parentId');
for my $k (sort keys %want) {
  is($set->{notCreated}{$k}{type}, 'invalidProperties', "$k: invalidProperties");
  ok((grep { $_ eq $want{$k} } @{ $set->{notCreated}{$k}{properties} || [] }), "$k: names $want{$k}")
    or diag explain $set->{notCreated}{$k};
}

# client-set values the server cannot store live in the mirror (R4) and survive a sync
($set) = @{ jmap(['FileNode/set', { create => { dp => { parentId => $madeid, name => 'dp.txt', blobId => $blob->{blobId},
  modified => '2001-02-03T04:05:06Z', created => '2000-01-01T00:00:00Z', executable => JSON::true, isSubscribed => JSON::false } } }]) };
my $dp = $set->{created}{dp};
ok($dp && $dp->{id}, 'created with client-set properties') or diag explain $set;
ok(!exists $dp->{modified} && !exists $dp->{executable}, 'values the client sent are not echoed');
force_sync();
my $dpg = get1($dp->{id});
is($dpg->{modified}, '2001-02-03T04:05:06Z', 'modified kept across a sync');
is($dpg->{created}, '2000-01-01T00:00:00Z', 'created kept');
is($dpg->{executable}, JSON::true, 'executable kept');
is($dpg->{isSubscribed}, JSON::false, 'isSubscribed kept');
is($dpg->{size}, 8, 'the server size is still the server size');

($set) = @{ jmap(['FileNode/set', { destroy => [ $top->{id} ] }]) };
is($set->{notDestroyed}{ $top->{id} }{type}, 'nodeHasChildren', 'non-empty directory without onDestroyRemoveChildren');
($set) = @{ jmap(['FileNode/set', { destroy => [ $home->{id}, 'Lnosuchnode' ] }]) };
is($set->{notDestroyed}{ $home->{id} }{type}, 'forbidden', 'the home cannot be destroyed');
is($set->{notDestroyed}{Lnosuchnode}{type}, 'notFound', 'unknown id');

# destroying a directory together with all its contents needs no flag
my ($kids) = @{ jmap(['FileNode/get', { ids => undef }]) };
my @under = map { $_->{id} } grep { ($_->{parentId} // '') eq $madeid } @{$kids->{list}};
($set) = @{ jmap(['FileNode/set', { destroy => [ $madeid, @under ] }]) };
is_deeply([ sort @{ $set->{destroyed} || [] } ], [ sort $madeid, @under ], 'directory plus every child, in one call') or diag explain $set;

# and with onDestroyRemoveChildren every descendant is listed
($set) = @{ jmap(['FileNode/set', { create => {
  d1 => { parentId => $top->{id}, name => 'd1' }, d2 => { parentId => '#d1', name => 'd2' },
  f  => { parentId => '#d2', name => 'f', blobId => $blob->{blobId} } } }]) };
my @made = map { $set->{created}{$_}{id} } qw(d1 d2 f);
($set) = @{ jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $top->{id} ] }]) };
is_deeply([ sort @{ $set->{destroyed} || [] } ], [ sort $top->{id}, @made ], 'destroyed with all its descendants listed') or diag explain $set;
is($dav->Raw('PROPFIND', "$root/$tag2/", undef, Depth => 0)->{status}, 404, 'gone from the server');
force_sync();
my ($gone) = @{ jmap(['FileNode/get', { ids => [ $top->{id}, @made ] }]) };
is(scalar @{$gone->{list}}, 0, 'and stays gone after a sync');

# a child added behind the proxy's back (the mirror has not seen it yet) still blocks a destroy
my ($ed) = @{ jmap(['FileNode/set', { create => { e => { parentId => $home->{id}, name => "$tag-empty" } } }]) };
my $edid = $ed->{created}{e}{id};
$dav->Put("$root/$tag-empty/sneaky.txt", "s", type => 'text/plain');
($set) = @{ jmap(['FileNode/set', { destroy => [ $edid ] }]) };
is($set->{notDestroyed}{$edid}{type}, 'nodeHasChildren', 'an unseen child is nodeHasChildren') or diag explain $set;
is($dav->Get("$root/$tag-empty/sneaky.txt")->{content}, 's', 'and it is not deleted');
($set) = @{ jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $edid ] }]) };
is(scalar @{ $set->{destroyed} || [] }, 2, 'with the flag: the directory and the child the re-list found') or diag explain $set;

# destroy a and create a in one call: the name is free at the end
my ($mk) = @{ jmap(['FileNode/set', { create => { a => { parentId => $home->{id}, name => "$tag-a", blobId => $blob->{blobId} } } }]) };
($set) = @{ jmap(['FileNode/set', { destroy => [ $mk->{created}{a}{id} ],
  create => { a2 => { parentId => $home->{id}, name => "$tag-a", blobId => $blob->{blobId} } } }]) };
ok($set->{created}{a2}, 'destroy-then-create of the same name in one /set') or diag explain $set;
is_deeply($set->{destroyed}, [ $mk->{created}{a}{id} ], 'and the destroy is reported');
jmap(['FileNode/set', { destroy => [ $set->{created}{a2}{id} ] }]);

# --- downloads and direct writes (Task 7)
my ($mkf) = @{ jmap(['FileNode/set', { create => { f => { parentId => $home->{id}, name => "$tag-dl.txt", blobId => $blob->{blobId} } } }]) };
my $fid = $mkf->{created}{f}{id};
my $fb = get1($fid)->{blobId};
sub raw { $http->get("$ENV{JMAP_PROXY_URL}/raw/$user/$_[0]/x.txt?type=text/plain", { headers => { Authorization => $auth } }) }
is(raw($fb)->{content}, 'uploaded', 'download a FileNode blob');

my ($cp) = @{ jmap(['FileNode/set', { create => { c => { parentId => $home->{id}, name => "$tag-copy.txt", blobId => $fb } } }]) };
ok($cp->{created}{c}, 'create a file from another FileNode blob') or diag explain $cp;
is(raw(get1($cp->{created}{c}{id})->{blobId})->{content}, 'uploaded', 'with the same content');

my $put = $http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid",
  { headers => { Authorization => $auth, 'Content-Type' => 'text/markdown; charset=utf-8' }, content => '# new' });
is($put->{status}, 200, 'direct PUT') or diag $put->{content};
my $pj = decode_json($put->{content});
is($pj->{size}, 5, 'size');
is($pj->{type}, 'text/markdown', 'type without parameters');
isnt($pj->{blobId}, $fb, 'new blobId');
is(get1($fid)->{blobId}, $pj->{blobId}, 'the node carries the new blobId');
is(raw($pj->{blobId})->{content}, '# new', 'new content downloads');
is(raw($fb)->{status}, 404, 'the old blob no longer exists');
$dav->Put("$root/$tag-dl.txt", "behind", type => 'text/plain');
is($http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid", { headers => { Authorization => $auth }, content => 'x' })->{status}, 412,
   'a change behind the mirror is 412');
is($http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/$home->{id}", { headers => { Authorization => $auth }, content => 'x' })->{status}, 400,
   'PUT to a directory is 400');
is($http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/Lnosuchnode", { headers => { Authorization => $auth }, content => 'x' })->{status}, 404,
   'PUT to an unknown id is 404');
is($http->request('PATCH', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid", { headers => { Authorization => $auth }, content => 'x' })->{status}, 415,
   'PATCH is 415');
my $gp = $http->request('GET', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid", { headers => { Authorization => $auth } });
is($gp->{status}, 405, 'GET is 405');
is($gp->{headers}{allow}, 'PUT', 'with Allow: PUT');
is($http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid", { content => 'x' })->{status}, 401, 'unauthenticated is 401');
force_sync();
jmap(['FileNode/set', { destroy => [ $fid, $cp->{created}{c}{id} ] }]);

# --- update (Task 8)
my ($u0) = @{ jmap(['FileNode/set', { create => {
  P => { parentId => $home->{id}, name => "$tag-P" },
  Q => { parentId => '#P', name => 'Q' },
  a => { parentId => '#P', name => 'a.txt', blobId => $blob->{blobId} },
  b => { parentId => '#P', name => 'b.txt', blobId => $blob->{blobId} },
} }]) };
my %id = map { $_ => $u0->{created}{$_}{id} } qw(P Q a b);

my ($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { name => 'b.txt' }, $id{b} => { name => 'a.txt' } } }]) };
ok(exists $u->{updated}{$id{a}} && exists $u->{updated}{$id{b}}, 'swap two names in one /set') or diag explain $u;
my ($ga) = @{ jmap(['FileNode/get', { ids => [ $id{a} ], properties => ['name'] }]) };
is($ga->{list}[0]{name}, 'b.txt', 'a is now b.txt, same id');

($u) = @{ jmap(['FileNode/set', { update => { $id{P} => { parentId => $id{Q} } } }]) };
is($u->{notUpdated}{$id{P}}{type}, 'invalidProperties', 'moving a directory into its own child');
is_deeply($u->{notUpdated}{$id{P}}{properties}, ['parentId'], 'on parentId');

($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { parentId => $id{Q}, name => "x y %#.txt" } } }]) };
ok(exists $u->{updated}{$id{a}}, 'move and rename together') or diag explain $u;
ok((grep { $_->{href} eq "$root/$tag-P/Q/x y %#.txt" } @{ $dav->PropFind("$root/$tag-P/Q/", 1) }), 'moved on the server');
is(raw(get1($id{a})->{blobId})->{content}, 'uploaded', 'and its content downloads after the MOVE');

($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { executable => JSON::true, accessed => '2026-01-02T03:04:05Z' } } }]) };
my ($gx) = @{ jmap(['FileNode/get', { ids => [ $id{a} ], properties => ['executable', 'accessed'] }]) };
ok($gx->{list}[0]{executable}, 'executable round-trips even where dead props are not stored');
is($gx->{list}[0]{accessed}, '2026-01-02T03:04:05Z', 'accessed round-trips');

($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { nodeType => 'directory' } } }]) };
is($u->{notUpdated}{$id{a}}{type}, 'invalidProperties', 'nodeType is immutable');

my $blob3 = upload("second!");
($u) = @{ jmap(['FileNode/set', { update => { $id{b} => { blobId => $blob3->{blobId} } } }]) };
is($u->{updated}{$id{b}}{size}, 7, 'content replaced; size reported') or diag explain $u;
is(raw($u->{updated}{$id{b}}{blobId})->{content}, 'second!', 'the new content downloads');

# a directory moves with what is in it
($u) = @{ jmap(['FileNode/set', { update => { $id{Q} => { parentId => $home->{id}, name => "$tag-Q" } } }]) };
ok(exists $u->{updated}{$id{Q}}, 'move a directory') or diag explain $u;
is(raw(get1($id{a})->{blobId})->{content}, 'uploaded', 'a file inside it still downloads');
force_sync();
is(get1($id{a})->{parentId}, $id{Q}, 'and keeps its id and parent across a sync');

# R6: a directory destroyed while its child moves out, in one call
($u) = @{ jmap(['FileNode/set', { destroy => [ $id{Q} ], update => { $id{a} => { parentId => $id{P} } } }]) };
is_deeply($u->{destroyed}, [ $id{Q} ], 'destroy a directory whose only child moves out') or diag explain $u;
ok(exists $u->{updated}{$id{a}}, 'and the child moved');

jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $id{P} ] }]);

# --- update, fix round 1: replace of an ancestor; content inside a moving directory
my ($r1) = @{ jmap(['FileNode/set', { create => {
  R => { parentId => $home->{id}, name => "$tag-R" },
  s => { parentId => '#R', name => 'sub' },
  a => { parentId => '#s', name => 'a.txt', blobId => $blob->{blobId} },
} }]) };
my %rid = map { $_ => $r1->{created}{$_}{id} } qw(R s a);
($u) = @{ jmap(['FileNode/set', { onExists => 'replace', onDestroyRemoveChildren => JSON::true,
                                  update => { $rid{a} => { parentId => $rid{R}, name => 'sub' } } }]) };
ok(exists $u->{updated}{$rid{a}}, 'a file replaces its own parent directory') or diag explain $u;
is_deeply($u->{destroyed}, [ $rid{s} ], 'the directory is destroyed');
is(raw(get1($rid{a})->{blobId})->{content}, 'uploaded', 'and the file survives with its content');
($u) = @{ jmap(['FileNode/set', { create => { d => { parentId => $rid{R}, name => 'd' },
                                              f => { parentId => '#d', name => 'f.txt', blobId => $blob->{blobId} } } }]) };
my ($dd, $ff) = ($u->{created}{d}{id}, $u->{created}{f}{id});
($u) = @{ jmap(['FileNode/set', { update => { $dd => { name => 'd2' }, $ff => { blobId => $blob3->{blobId} } } }]) };
is($u->{updated}{$ff}{size}, 7, 'move a directory and replace a file\'s content inside it, in one call') or diag explain $u;
is(raw($u->{updated}{$ff}{blobId})->{content}, 'second!', 'the new content downloads');
jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $rid{R} ] }]);

# --- query (Task 9)
my ($qb) = @{ jmap(['FileNode/query', { filter => { body => 'x' } }]) };
is($qb->{type}, 'unsupportedFilter', 'body filter is unsupported');

my ($qn) = @{ jmap(['FileNode/set', { create => { d1 => { parentId => $home->{id}, name => "$tag-deep" },
  d2 => { parentId => '#d1', name => 'd2' }, f3 => { parentId => '#d2', name => 'f3', blobId => $blob->{blobId} } } }]) };
my ($qq) = @{ jmap(['FileNode/query', { filter => { ancestorId => $home->{id} }, sort => [ { property => 'tree' } ] }]) };
is_deeply($qq->{ids}, [ map { $qn->{created}{$_}{id} } qw(d1 d2 f3) ], 'tree query over the home directory: depth-first') or diag explain $qq;
my ($q0) = @{ jmap(['FileNode/query', { filter => { parentId => $qn->{created}{d1}{id} } }]) };
is_deeply($q0->{ids}, [ $qn->{created}{d2}{id} ], 'depth 0: children only');
my ($q1) = @{ jmap(['FileNode/query', { filter => { parentId => $qn->{created}{d1}{id} }, depth => 1 }]) };
is_deeply([ sort @{$q1->{ids}} ], [ sort $qn->{created}{d2}{id}, $qn->{created}{f3}{id} ], 'depth 1: one level further');
jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $qn->{created}{d1}{id} ] }]);

# queryChanges: a created node is added, a destroyed one removed
my ($qa) = @{ jmap(['FileNode/query', { filter => { parentId => $home->{id} }, sort => [ { property => 'name' } ] }]) };
my ($qc) = @{ jmap(['FileNode/set', { create => { n => { parentId => $home->{id}, name => "$tag-qc" } } }]) };
my $nid = $qc->{created}{n}{id};
my ($qd) = @{ jmap(['FileNode/queryChanges', { filter => { parentId => $home->{id} }, sort => [ { property => 'name' } ],
                                              sinceQueryState => $qa->{queryState} }]) };
is_deeply([ map { $_->{id} } @{$qd->{added}} ], [ $nid ], 'queryChanges: the new node is added') or diag explain $qd;
is_deeply($qd->{removed}, [], 'and nothing removed');
my ($qe) = @{ jmap(['FileNode/queryChanges', { filter => { parentId => $home->{id} }, sort => [ { property => 'size' } ],
                                              sinceQueryState => $qa->{queryState} }]) };
is($qe->{type}, 'cannotCalculateChanges', 'queryChanges with other parameters cannot be calculated');
my ($qs) = @{ jmap(['FileNode/query', { sort => [ { property => 'name', collation => 'i;bogus' } ] }]) };
is($qs->{type}, 'unsupportedSort', 'unknown collation');
jmap(['FileNode/set', { destroy => [ $nid ] }]);

# --- query fix round 1
my ($tc) = @{ jmap(['FileNode/set', { create => {
  z => { parentId => $home->{id}, name => "$tag-zdir" },
  a => { parentId => '#z', name => 'a.txt', blobId => $blob->{blobId} },
  c => { parentId => '#z', name => 'c.txt', blobId => $blob->{blobId} },
  b => { parentId => $home->{id}, name => "$tag-b.txt", blobId => $blob->{blobId} },
} }]) };
my %t = map { $_ => $tc->{created}{$_}{id} } qw(z a c b);
my $tfilter = { operator => 'AND', conditions => [ { nodeType => 'file' }, { nameMatch => '*.txt' }, { ancestorId => $home->{id} } ] };
my ($tf) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => [ { property => 'tree' } ] }]) };
my @mine = grep { my $i = $_; grep { $_ eq $i } values %t } @{$tf->{ids}};
is_deeply(\@mine, [ $t{b}, $t{a}, $t{c} ], 'tree over files only keeps the directory hierarchy (home/b, zdir/a, zdir/c)') or diag explain $tf;

# positions, limits, anchors
my ($p0) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => [ { property => 'tree' } ], calculateTotal => JSON::true }]) };
my @all = @{$p0->{ids}};
my ($pn) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => [ { property => 'tree' } ], position => -1 }]) };
is_deeply($pn->{ids}, [ $all[-1] ], 'position -1 is the last id, no duplicates') or diag explain $pn;
is($pn->{position}, $#all, 'and reports the resolved position');
my ($pl) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => [ { property => 'tree' } ], limit => -1 }]) };
is($pl->{type}, 'invalidArguments', 'negative limit');
my ($pa) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => [ { property => 'tree' } ], anchor => $all[1], anchorOffset => -1, limit => 2 }]) };
is_deeply($pa->{ids}, [ @all[0, 1] ], 'anchor with negative offset and limit') or diag explain $pa;
my ($pm) = @{ jmap(['FileNode/query', { anchor => 'nope' }]) };
is($pm->{type}, 'anchorNotFound', 'unknown anchor');
my ($pw) = @{ jmap(['FileNode/query', { filter => { isTopLevel => 'false' } }]) };
is($pw->{type}, 'invalidArguments', 'filter value of the wrong type');
my ($pd) = @{ jmap(['FileNode/query', { filter => { parentId => $home->{id} }, depth => undef }]) };
ok($pd->{ids}, 'depth null is accepted');
my ($ps) = @{ jmap(['FileNode/queryChanges', { filter => $tfilter }]) };
is($ps->{type}, 'invalidArguments', 'queryChanges needs sinceQueryState');

# queryChanges: a renamed directory moves its descendants under tree
my $tsort = [ { property => 'tree' } ];
my ($b1) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => $tsort }]) };
jmap(['FileNode/set', { update => { $t{z} => { name => "$tag-zzz" } } }]);
my ($qr) = @{ jmap(['FileNode/queryChanges', { filter => $tfilter, sort => $tsort, sinceQueryState => $b1->{queryState} }]) };
my %rm = map { $_ => 1 } @{$qr->{removed}};
my %ad = map { $_->{id} => $_->{index} } @{$qr->{added}};
ok($rm{$t{a}} && $rm{$t{c}} && exists $ad{$t{a}} && exists $ad{$t{c}},
   'tree queryChanges: renaming a directory removes and re-adds its descendants') or diag explain $qr;
my ($b2) = @{ jmap(['FileNode/query', { filter => $tfilter, sort => $tsort }]) };
for my $e (@{$qr->{added}}) { is($b2->{ids}[$e->{index}], $e->{id}, "added index for $e->{id} matches the new query") }

# an updated node is removed and re-added; maxChanges
my ($uq) = @{ jmap(['FileNode/query', { filter => { parentId => $t{z} }, sort => [ { property => 'name' } ] }]) };
jmap(['FileNode/set', { update => { $t{a} => { executable => JSON::true } } }]);
my ($u1) = @{ jmap(['FileNode/queryChanges', { filter => { parentId => $t{z} }, sort => [ { property => 'name' } ], sinceQueryState => $uq->{queryState} }]) };
is_deeply($u1->{removed}, [ $t{a} ], 'an updated node is removed') or diag explain $u1;
is_deeply($u1->{added}, [ { id => $t{a}, index => 0 } ], 'and re-added at its index');
my ($u2) = @{ jmap(['FileNode/queryChanges', { filter => { parentId => $t{z} }, sort => [ { property => 'name' } ], sinceQueryState => $uq->{queryState}, maxChanges => 1 }]) };
is($u2->{type}, 'tooManyChanges', 'maxChanges exceeded');
my ($u3) = @{ jmap(['FileNode/queryChanges', { filter => { parentId => $t{z} }, sort => [ { property => 'name' } ], sinceQueryState => $uq->{queryState}, maxChanges => 0 }]) };
is($u3->{type}, 'invalidArguments', 'maxChanges 0 is invalid');
jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $t{z}, $t{b} ] }]);

# --- sharing (Task 10): shareWith over the WebDAV ACL
SKIP: {
  my $sharee = $ENV{CYRUS_SHAREE} || ($user eq 'user2' ? 'user1' : 'user2');
  my $peer = JMAP::Sync::WebDAVTalk->new(user => $sharee, password => 'x', url => "$ENV{CYRUS_URL}/dav/drive/user/$user/");
  skip "the WebDAV server has no ACL support (Probe): shareWith is covered by t/filenode-set.t's fake server", 1
    unless $dav->GetAcl("$root/");
  my $principal = $dav->Raw('PROPFIND', "/dav/principals/user/$sharee/", undef, Depth => 0)->{status};
  if ($principal == 404) {
    # a clean stack has only the test user: provision the sharee (the Cyrus
    # container's management API needs a body on PUT)
    my $cmgmt = ($ENV{CYRUS_MGMT_URL} || 'http://localhost:8001') =~ s{/\z}{}r;
    $http->put("$cmgmt/api/$sharee", { headers => { 'Content-Type' => 'application/json' },
      content => encode_json({ mailboxes => [ { name => 'INBOX', subscribed => JSON::true } ], quota_kb => 102400 }) });
    # Cyrus makes a user's DAV principal on their first DAV request
    $peer->Raw('PROPFIND', "/dav/principals/user/$sharee/", undef, Depth => 0);
    $principal = $dav->Raw('PROPFIND', "/dav/principals/user/$sharee/", undef, Depth => 0)->{status};
  }
  skip "no user $sharee on the test server (principal: HTTP $principal)", 1 if $principal == 404;
  my $t = JSON::true; my $f = JSON::false;
  my %none = map { ($_ => $f) } qw(mayRead mayAddChildren mayRename mayDelete mayModifyContent mayShare);
  my ($sd) = @{ jmap(['FileNode/set', { create => { s => { parentId => $home->{id}, name => "$tag-shared" },
                                                    sf => { parentId => '#s', name => 'inside.txt', blobId => $blob->{blobId} },
                                                    sub => { parentId => '#s', name => 'sub' },
                                                    deep => { parentId => '#sub', name => 'deep.txt', blobId => $blob->{blobId} } } }]) };
  my $subid = $sd->{created}{sub}{id};
  my $sid = $sd->{created}{s}{id};
  ok($sid && $sd->{created}{sf}, 'a directory to share, with a file in it') or diag explain $sd;
  my ($g0) = @{ jmap(['FileNode/get', { ids => [ $sid, $sd->{created}{sf}{id} ], properties => [ 'myRights', 'shareWith' ] }]) };
  my %g0 = map { $_->{id} => $_ } @{$g0->{list}};
  ok($g0{$sid}{myRights}{mayShare}, 'the owner may share a directory');
  is($g0{$sid}{shareWith}, undef, 'shared with nobody yet');
  ok(!$g0{ $sd->{created}{sf}{id} }{myRights}{mayShare}, 'a file is not shareable (spec "Sharing")');
  is($peer->Raw('GET', "$root/$tag-shared/inside.txt")->{status}, 403, "$sharee cannot read it yet");

  my $before = $g0->{state};
  my ($ss) = @{ jmap(['FileNode/set', { update => { $sid => { shareWith => { $sharee => { %none, mayRead => $t } } } } }]) };
  ok(exists $ss->{updated}{$sid}, 'shareWith set') or diag explain $ss;
  my $acl = $dav->GetAcl("$root/$tag-shared/");
  ok((grep { $_->{principal} =~ m{/\Q$sharee\E/$} && grep { $_ eq 'read' } @{$_->{grant}} } @$acl), "an ACE for $sharee with read")
    or diag explain $acl;
  ok((grep { $_->{principal} eq 'self' && grep { $_ eq 'all' } @{$_->{grant}} } @$acl), 'the owner keeps every right') or diag explain $acl;
  my ($sg) = @{ jmap(['FileNode/get', { ids => [ $sid ], properties => ['shareWith'] }]) };
  is_deeply($sg->{list}[0]{shareWith}, { $sharee => { %none, mayRead => $t } }, 'shareWith reads back');
  my ($sc) = @{ jmap(['FileNode/changes', { sinceState => $before }]) };
  ok((grep { $_ eq $sid } @{$sc->{updated}}), 'FileNode/changes reports the node') or diag explain $sc;
  ok((grep { $_ eq $subid } @{$sc->{updated}}), 'and the subdirectory the share reached') or diag explain $sc;
  is($peer->Raw('GET', "$root/$tag-shared/inside.txt")->{status}, 200, "$sharee can read the file now");
  # Cyrus keeps ACLs per collection: the proxy carries the share to the
  # subdirectory that already existed (draft "Access Control")
  is($peer->Raw('GET', "$root/$tag-shared/sub/deep.txt")->{status}, 200, "$sharee can read a file in the subdirectory too");
  my ($ssub) = @{ jmap(['FileNode/get', { ids => [ $subid ], properties => ['shareWith'] }]) };
  is_deeply($ssub->{list}[0]{shareWith}, { $sharee => { %none, mayRead => $t } }, 'the subdirectory\'s shareWith says so');
  is($peer->Put("$root/$tag-shared/new.txt", 'x', type => 'text/plain')->{status}, 403, 'but not write');

  # a directory moved into the shared one is shared with it, and moved out again is not
  my ($mv) = @{ jmap(['FileNode/set', { create => { m => { parentId => $home->{id}, name => "$tag-mover" },
                                                    mf => { parentId => '#m', name => 'moved.txt', blobId => $blob->{blobId} } } }]) };
  my $mid = $mv->{created}{m}{id};
  ok($mid, 'a directory to move') or diag explain $mv;
  is($peer->Raw('GET', "$root/$tag-mover/moved.txt")->{status}, 403, "$sharee cannot read it where it is");
  my ($mi) = @{ jmap(['FileNode/set', { update => { $mid => { parentId => $sid } } }]) };
  ok(exists $mi->{updated}{$mid}, 'moved into the shared directory') or diag explain $mi;
  is($peer->Raw('GET', "$root/$tag-shared/$tag-mover/moved.txt")->{status}, 200, "$sharee can read the moved file");
  my ($mo) = @{ jmap(['FileNode/set', { update => { $mid => { parentId => $home->{id} } } }]) };
  ok(exists $mo->{updated}{$mid}, 'moved back out') or diag explain $mo;
  is($peer->Raw('GET', "$root/$tag-mover/moved.txt")->{status}, 403, "$sharee cannot read it any more");
  jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $mid ] }]);

  # a patch path; mayShare is Cyrus's admin privilege (write-acl is abstract there)
  my ($sp) = @{ jmap(['FileNode/set', { update => { $sid => { "shareWith/$sharee/mayShare" => $t } } }]) };
  ok(exists $sp->{updated}{$sid}, 'patched mayShare') or diag explain $sp;
  ($sg) = @{ jmap(['FileNode/get', { ids => [ $sid ], properties => ['shareWith'] }]) };
  ok($sg->{list}[0]{shareWith}{$sharee}{mayShare}, 'and it reads back') or diag explain $sg;

  # a sharee who is no user
  my ($sn) = @{ jmap(['FileNode/set', { update => { $sid => { 'shareWith/nosuchuser' => { mayRead => $t } } } }]) };
  is($sn->{notUpdated}{$sid}{type}, 'invalidProperties', 'no such user: invalidProperties') or diag explain $sn;
  # a hostile id never reaches the server
  ($sn) = @{ jmap(['FileNode/set', { update => { $sid => { shareWith => { qq{a"b</D:href>} => { mayRead => $t } } } } }]) };
  is($sn->{notUpdated}{$sid}{type}, 'invalidProperties', 'an id that is no safe principal name: invalidProperties');

  # null clears; the owner still has everything
  my ($sx) = @{ jmap(['FileNode/set', { update => { $sid => { shareWith => undef } } }]) };
  ok(exists $sx->{updated}{$sid}, 'cleared') or diag explain $sx;
  $acl = $dav->GetAcl("$root/$tag-shared/");
  ok(!(grep { $_->{principal} =~ m{/\Q$sharee\E/$} } @$acl), "no ACE for $sharee") or diag explain $acl;
  is($peer->Raw('GET', "$root/$tag-shared/inside.txt")->{status}, 403, "$sharee cannot read it any more");
  is($peer->Raw('GET', "$root/$tag-shared/sub/deep.txt")->{status}, 403, 'nor the file in the subdirectory');
  ok(scalar(grep { $_->{href} eq "$root/$tag-shared/inside.txt" } @{ $dav->PropFind("$root/$tag-shared/", 1) }), 'the owner still lists it');

  # an ACL changed behind the proxy's back
  $dav->SetAcl("$root/$tag-shared/", [ { principal => 'self', grant => ['all'] },
                                       { principal => "/dav/principals/user/$sharee/", grant => [ 'read', 'bind' ] } ]);
  force_sync();
  ($sg) = @{ jmap(['FileNode/get', { ids => [ $sid ], properties => ['shareWith'] }]) };
  ok($sg->{list}[0]{shareWith}{$sharee}{mayAddChildren}, 'an ACL set elsewhere shows up after a sync') or diag explain $sg;
  jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $sid ] }]);
}

# --- FileNode/copy across accounts (Task 11).  RFC 8620 S5.4: fromAccountId
# and accountId differ; the parent orchestrates it (fetch_blobs/store_blob,
# then one FileNode/set in the destination).  A second proxy account with a
# drive, in this account's pool.
SKIP: {
  my $other = $ENV{CYRUS_OTHER_USER} || ($user eq 'user2' ? 'user1' : 'user2');
  my $odav = JMAP::Sync::WebDAVTalk->new(user => $other, password => 'x', url => "$ENV{CYRUS_URL}/dav/drive/user/$other/");
  my $oroot = "/dav/drive/user/$other";
  if ($odav->Raw('PROPFIND', "$oroot/", undef, Depth => 0)->{status} == 404
      && $odav->Raw('PROPFIND', "/dav/principals/user/$other/", undef, Depth => 0)->{status} == 404) {
    my $cmgmt = ($ENV{CYRUS_MGMT_URL} || 'http://localhost:8001') =~ s{/\z}{}r;
    $http->put("$cmgmt/api/$other", { headers => { 'Content-Type' => 'application/json' },
      content => encode_json({ mailboxes => [ { name => 'INBOX', subscribed => JSON::true } ], quota_kb => 102400 }) });
    $odav->Raw('PROPFIND', "/dav/principals/user/$other/", undef, Depth => 0);
  }
  my $ost = $odav->Raw('PROPFIND', "$oroot/", undef, Depth => 0)->{status};
  skip "no drive for $other on the test server (HTTP $ost)", 1 unless $ost == 207;
  # registered the way bin/restart-test-proxy.sh registers the test user,
  # in the test user's pool so one login sees both accounts; whatever an
  # earlier run left goes first, and this one's goes however the block ends
  $http->delete("$mgmt/api/accounts/$other");
  my ($ojmap, $ohome, %src);
  my $guard = bless sub {
    eval {
      if ($ohome) {
        # no staged copy is ever left behind, on the server either
        my @staged = grep { $_->{href} =~ m{/\.jmap-copy-} } @{ $odav->PropFind("$oroot/", 1) };
        ok(!@staged, 'no staged copy left in the destination') or diag explain \@staged;
        # Cyrus refuses (500) a second DELETE of one collection name within
        # the same second (its delayed-delete names collide): once more, later
        for my $try (1, 2) {
          my ($oq) = @{ $ojmap->('FileNode/query', { filter => { operator => 'OR', conditions => [
            { parentId => $ohome->{id}, nameMatch => "$tag*" }, { parentId => $ohome->{id}, nameMatch => '.jmap-copy-*' } ] } }) };
          my ($od) = @{ $ojmap->('FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => $oq->{ids} || [] }) };
          last unless $od->{notDestroyed};
          sleep 2;
        }
      }
      jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ grep { defined && get1($_) } @src{qw(one d)} ] }]);
      1;
    } or diag "tidying up: $@";
    $http->delete("$mgmt/api/accounts/$other");
  }, 'TestGuard';
  my $reg = $http->post("$mgmt/api/accounts", { headers => { 'Content-Type' => 'application/json' },
    content => encode_json({ accountid => $other, email => $other, type => 'imap', username => $other,
      password => 'password', imapHost => 'localhost', imapPort => ($ENV{CYRUS_IMAP_PORT} || 8143), imapSSL => 1,
      smtpHost => 'localhost', smtpPort => 25, smtpSSL => 1, caldavURL => $ENV{CYRUS_URL}, carddavURL => $ENV{CYRUS_URL},
      webdavURL => "$ENV{CYRUS_URL}/dav/drive/user/$other/", poolid => $user }) });
  skip "registering $other: HTTP $reg->{status} $reg->{content}", 1 unless $reg->{success};
  my $osess = decode_json($http->get("$ENV{JMAP_PROXY_URL}/.well-known/jmap", { headers => { Authorization => $auth } })->{content});
  ok($osess->{accounts}{$other}, "the session lists $other");
  $ojmap = sub { my ($m, $a) = @_; jmap([ $m, { accountId => $other, %$a } ]) };
  my ($oall) = @{ $ojmap->('FileNode/get', { ids => undef }) };
  ($ohome) = grep { !defined $_->{parentId} } @{ $oall->{list} || [] };
  ok($ohome, "$other has a home directory") or diag explain $oall;

  # source: a directory with a file, a subdirectory and a file in that,
  # and a lone file with client-set properties
  my $exe = upload("#!/bin/sh\necho $tag\n");
  my ($cs) = @{ jmap(['FileNode/set', { create => {
    d   => { parentId => $home->{id}, name => "$tag-src" },
    f   => { parentId => '#d', name => 'f.txt', blobId => $blob->{blobId}, type => 'text/plain' },
    sub => { parentId => '#d', name => 'sub' },
    g   => { parentId => '#sub', name => 'g.sh', blobId => $exe->{blobId}, type => 'text/x-sh',
             executable => JSON::true, modified => '2020-01-02T03:04:05Z' },
    one => { parentId => $home->{id}, name => "$tag-one.sh", blobId => $exe->{blobId}, type => 'text/x-sh',
             executable => JSON::true, created => '2019-05-06T07:08:09Z', modified => '2020-01-02T03:04:05Z' } } }]) };
  is(scalar keys %{ $cs->{created} || {} }, 5, 'source tree created') or diag explain $cs;
  %src = map { ($_ => $cs->{created}{$_}{id}) } keys %{ $cs->{created} || {} };

  # same account: the error every /copy gives for it
  my ($same) = @{ jmap(['FileNode/copy', { fromAccountId => $user, create => { x => { id => $src{one}, parentId => $home->{id} } } }]) };
  is($same->{type}, 'invalidArguments', 'fromAccountId = accountId: invalidArguments, as for every /copy') or diag explain $same;

  my ($cp) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, create => {
    c   => { id => $src{d}, parentId => $ohome->{id} },
    o   => { id => $src{one}, parentId => $ohome->{id}, name => "$tag-renamed.sh" },
    nf  => { id => 'Lnosuchnode', parentId => $ohome->{id} },
    np  => { id => $src{one}, parentId => 'Lnosuchparent', name => "$tag-np.sh" } } }) };
  ok($cp->{created}{c}{id}, 'a directory copied') or diag explain $cp;
  ok($cp->{created}{o}{id}, 'a file copied under a new name') or diag explain $cp;
  isnt($cp->{created}{c}{id}, $src{d}, 'a new id');
  is($cp->{fromAccountId}, $user, 'fromAccountId');
  is($cp->{accountId}, $other, 'accountId');
  ok(defined $cp->{oldState} && defined $cp->{newState} && $cp->{oldState} ne $cp->{newState}, 'the destination state moved');
  is($cp->{notCreated}{nf}{type}, 'notFound', 'an unknown source: notFound') or diag explain $cp;
  is($cp->{notCreated}{np}{type}, 'invalidProperties', 'an unknown destination parent: invalidProperties');
  my @dest = map { $_->{href} } @{ $odav->PropFind("$oroot/$tag-src/sub/", 1) }, @{ $odav->PropFind("$oroot/$tag-src/", 1) };
  ok((grep { $_ eq "$oroot/$tag-src/f.txt" } @dest), 'the file in the directory copied on the server') or diag explain \@dest;
  ok((grep { $_ eq "$oroot/$tag-src/sub/g.sh" } @dest), 'and the one in the subdirectory') or diag explain \@dest;
  is($odav->Raw('GET', "$oroot/$tag-src/sub/g.sh")->{content}, "#!/bin/sh\necho $tag\n", 'with its content');
  my ($q) = @{ $ojmap->('FileNode/query', { filter => { ancestorId => $cp->{created}{c}{id} }, sort => [ { property => 'tree' } ] }) };
  my ($qg) = @{ $ojmap->('FileNode/get', { ids => [ @{ $q->{ids} || [] }, $cp->{created}{o}{id} ] }) };
  my %byname = map { ($_->{name} => $_) } @{ $qg->{list} || [] };
  is_deeply([ sort keys %byname ], [ sort 'f.txt', 'sub', 'g.sh', "$tag-renamed.sh" ], 'the copied nodes, by FileNode/query') or diag explain $qg;
  is($byname{'g.sh'}{parentId}, $byname{sub}{id}, 'the hierarchy is kept');
  is($byname{'g.sh'}{executable}, JSON::true, 'executable carried');
  is($byname{'g.sh'}{type}, 'text/x-sh', 'type carried');
  is($byname{'g.sh'}{modified}, '2020-01-02T03:04:05Z', 'modified carried');
  is($byname{"$tag-renamed.sh"}{created}, '2019-05-06T07:08:09Z', 'created carried');
  is($byname{"$tag-renamed.sh"}{size}, length("#!/bin/sh\necho $tag\n"), 'size');
  is($byname{"$tag-renamed.sh"}{shareWith}, undef, 'no sharing carried');
  ok(scalar(grep { $_->{href} eq "$root/$tag-src/f.txt" } @{ $dav->PropFind("$root/$tag-src/", 1) }), 'the source is untouched');

  # a name taken in the destination: alreadyExists, or onExists "rename"
  my ($cx) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, create => { c => { id => $src{d}, parentId => $ohome->{id} } } }) };
  is($cx->{notCreated}{c}{type}, 'alreadyExists', 'a clash: alreadyExists') or diag explain $cx;
  is($cx->{notCreated}{c}{existingId}, $cp->{created}{c}{id}, 'naming the node in the way');
  my ($cr) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, onExists => 'rename',
                                            create => { c => { id => $src{d}, parentId => $ohome->{id} } } }) };
  ok($cr->{created}{c}{id} && $cr->{created}{c}{name} && $cr->{created}{c}{name} ne "$tag-src", 'onExists rename: a new name, returned')
    or diag explain $cr;

  # onExists "replace" of a directory: the copy is staged under another name
  # and renamed over the old one, so a failure never costs the old one
  my $oldid = $cp->{created}{c}{id};
  my ($rf) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, onExists => 'replace',
                                            create => { c => { id => $src{d}, parentId => $ohome->{id} } } }) };
  is($rf->{notCreated}{c}{type}, 'nodeHasChildren', 'replace of a directory with children, no onDestroyRemoveChildren: nodeHasChildren')
    or diag explain $rf;
  my ($kids) = @{ $ojmap->('FileNode/query', { filter => { parentId => $ohome->{id} } }) };
  my ($kg) = @{ $ojmap->('FileNode/get', { ids => $kids->{ids}, properties => ['name'] }) };
  ok((grep { $_->{id} eq $oldid && $_->{name} eq "$tag-src" } @{ $kg->{list} }), 'the old directory survives');
  ok(!(grep { $_->{name} =~ /^\.jmap-copy-/ } @{ $kg->{list} }), 'and no staged copy is left') or diag explain $kg;
  my ($rp) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, onExists => 'replace', onDestroyRemoveChildren => JSON::true,
                                            create => { c => { id => $src{d}, parentId => $ohome->{id} } } }) };
  ok($rp->{created}{c}{id}, 'replace with onDestroyRemoveChildren: copied') or diag explain $rp;
  ok((grep { $_ eq $oldid } @{ $rp->{destroyed} || [] }), 'the old directory listed as destroyed');
  is($odav->Raw('GET', "$oroot/$tag-src/sub/g.sh")->{content}, "#!/bin/sh\necho $tag\n", 'the copy is in its place');
  ok(!(grep { $_->{href} =~ /\.jmap-copy-/ } @{ $odav->PropFind("$oroot/", 1) }), 'under its own name');

  # the state checks, and a create without an id
  my ($sm) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, ifFromInState => 'nosuchstate',
                                            create => { c => { id => $src{one}, parentId => $ohome->{id} } } }) };
  is($sm->{type}, 'stateMismatch', 'ifFromInState') or diag explain $sm;
  my ($ni) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, create => { c => { parentId => $ohome->{id} } } }) };
  is_deeply($ni->{notCreated}{c}, { type => 'invalidProperties', properties => ['id'] }, 'no id: invalidProperties') or diag explain $ni;
  my $dres = $http->post("$ENV{JMAP_PROXY_URL}/jmap/", {
    headers => { Authorization => $auth, 'Content-Type' => 'application/json' },
    content => encode_json({ using => \@using, methodCalls => [
      [ 'FileNode/copy', { accountId => $other, fromAccountId => $user, onSuccessDestroyOriginal => JSON::true,
                           destroyFromIfInState => 'nosuchstate',
                           create => { c => { id => $src{one}, parentId => $ohome->{id}, name => "$tag-dfs.sh" } } }, 'k' ] ] }) });
  my $dm = decode_json($dres->{content})->{methodResponses};
  is_deeply([ map { "$_->[0] $_->[2]" } @$dm ], [ 'FileNode/copy k', 'error k' ], 'destroyFromIfInState: the copy, then the set\'s error')
    or diag explain $dm;
  is($dm->[1][1]{type}, 'stateMismatch', 'stateMismatch');
  ok(get1($src{one}), 'and the original stays');

  # the source changed behind the mirror's back (a 412 on its pinned blobId):
  # that item fails, as a whole and without leaving a partial copy; the rest
  # of the call goes ahead
  force_sync();
  $dav->Put("$root/$tag-src/sub/g.sh", "changed\n", type => 'text/x-sh');
  my ($c412) = @{ $ojmap->('FileNode/copy', { fromAccountId => $user, create => {
    c => { id => $src{d}, parentId => $ohome->{id}, name => "$tag-412" },
    o => { id => $src{f}, parentId => $ohome->{id}, name => "$tag-ok.txt" } } }) };
  ok($c412->{notCreated}{c}, 'a directory whose file changed underneath is not created') or diag explain $c412;
  like($c412->{notCreated}{c}{description} // '', qr/g\.sh/, 'the error names the file');
  ok($c412->{created}{o}{id}, 'the other item is copied');
  is($odav->Raw('PROPFIND', "$oroot/$tag-412/", undef, Depth => 0)->{status}, 404, 'no partial directory left behind');
  force_sync();

  # onSuccessDestroyOriginal: a move between accounts; the implicit
  # FileNode/set answers with the /copy's call id, after the /copy
  my $res = $http->post("$ENV{JMAP_PROXY_URL}/jmap/", {
    headers => { Authorization => $auth, 'Content-Type' => 'application/json' },
    content => encode_json({ using => \@using, methodCalls => [
      [ 'FileNode/copy', { accountId => $other, fromAccountId => $user, onSuccessDestroyOriginal => JSON::true,
                           create => { m => { id => $src{d}, parentId => $ohome->{id}, name => "$tag-moved" } } }, 'mv' ],
      [ 'Core/echo', { hello => 1 }, 'e' ] ] }) });
  my $mr = decode_json($res->{content})->{methodResponses};
  is_deeply([ map { "$_->[0] $_->[2]" } @$mr ], [ 'FileNode/copy mv', 'Core/echo e', 'FileNode/set mv' ],
            'the implicit FileNode/set is appended, with the /copy call id') or diag explain $mr;
  my ($mset) = map { $_->[1] } grep { $_->[0] eq 'FileNode/set' } @$mr;
  is_deeply([ sort @{ $mset->{destroyed} || [] } ], [ sort @src{qw(d f sub g)} ], 'the source directory and all it held destroyed')
    or diag explain $mr;
  is($dav->Raw('PROPFIND', "$root/$tag-src/", undef, Depth => 0)->{status}, 404, 'gone from the source drive');
  is($odav->Raw('GET', "$oroot/$tag-moved/sub/g.sh")->{content}, "changed\n", 'with its current content at the destination');

  # $guard tidies up: the copies, the source file, and the second account
}

package TestGuard { sub DESTROY { $_[0]->() } }

done_testing;
