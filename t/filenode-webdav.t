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

# the root (FileNode/query arrives in a later task: find it with a full /get)
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

done_testing;
