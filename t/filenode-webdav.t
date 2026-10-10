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
$dav->Put("$root/$tag/one.txt", "1", type => 'text/plain');
force_sync();
my ($c) = @{ jmap(['FileNode/changes', { sinceState => $state }]) };
is(scalar @{$c->{created}}, 2, 'external MKCOL + PUT are two creations') or diag explain $c;
my ($g2) = @{ jmap(['FileNode/get', { ids => $c->{created} }]) };
my ($file) = grep { $_->{name} eq 'one.txt' } @{$g2->{list}};
my ($dir)  = grep { $_->{name} eq $tag } @{$g2->{list}};
is($file->{parentId}, $dir->{id}, 'parent linkage');
is($dir->{parentId}, $home->{id}, 'directory under home');
is($file->{size}, 1, 'size');
is($file->{type}, 'text/plain', 'type');
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

done_testing;
