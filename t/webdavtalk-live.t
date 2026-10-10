#!/usr/bin/perl
# t/webdavtalk-live.t -- against Cyrus #drive (bin/restart-test-proxy.sh clean)
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::WebDAVTalk;
use Data::UUID::LibUUID qw(new_uuid_string);

plan skip_all => 'set CYRUS_URL to run' unless $ENV{CYRUS_URL};
my $user = $ENV{CYRUS_USER} || 'user1';
my $dav = JMAP::Sync::WebDAVTalk->new(user => $user, password => $ENV{CYRUS_PASS} || 'x',
                                      url => "$ENV{CYRUS_URL}/dav/drive/user/$user/");
my $root = "/dav/drive/user/$user";
my $dir = "$root/t-" . lc(new_uuid_string() =~ s/-//gr);

is($dav->Mkcol($dir), 201, 'MKCOL');
my $name = "$dir/a b%#caf\x{e9}.txt";
my $put = $dav->Put($name, "hello", type => 'text/plain', if_none_match => 1);
is($put->{status}, 201, 'PUT with a name needing escapes');
is($dav->Put($name, "again", if_none_match => 1)->{status}, 412, 'If-None-Match: * on an existing file is 412');

my $list = $dav->PropFind($dir, 1);
my ($f) = grep { $_->{href} eq $name } @$list;
ok($f, 'listing round-trips the escaped name') or diag explain $list;
is($f->{size}, 5, 'size');

is($dav->Get($name, if_match => 'nope')->{status}, 412, 'If-Match mismatch is 412');
is($dav->Get($name, if_match => $f->{etag})->{content}, 'hello', 'GET with If-Match');

is($dav->Move($name, "$dir/moved.txt"), 201, 'MOVE');
is($dav->Move("$dir/moved.txt", "$dir/moved.txt", overwrite => 0) =~ /^[45]/ ? 1 : 0, 1, 'MOVE onto itself is refused');

my $sync = $dav->SyncCollection($dir, '');
ok($sync && $sync->{token}, 'sync-collection at level 1 gives a token');

my $f2 = $dav->Probe($root);
ok(!$f2->{deadProps}, 'Cyrus: dead properties are detected as NOT stored') or diag explain $f2;
ok(!$f2->{etagIsContent}, 'Cyrus: ETags are not move-stable content hashes');
ok($f2->{syncCollection}, 'Cyrus: sync-collection');
ok($f2->{acl}, 'Cyrus: ACL');

$dav->Raw('DELETE', "$dir/");
done_testing;
