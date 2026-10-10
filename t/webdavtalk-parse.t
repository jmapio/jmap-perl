#!/usr/bin/perl
# t/webdavtalk-parse.t
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::WebDAVTalk;

my $parse = \&JMAP::Sync::WebDAVTalk::parse_multistatus;

# A Cyrus #drive Depth-1 listing (trimmed from the 2026-10-09 probe).
my $listing = <<'XML';
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
  <D:response>
    <D:href>/dav/drive/user/user1/docs/</D:href>
    <D:propstat><D:prop>
      <D:getetag>"1791596669-1-1"</D:getetag>
      <D:getlastmodified>Sat, 10 Oct 2026 01:44:12 GMT</D:getlastmodified>
      <D:creationdate>2026-10-10T01:44:12Z</D:creationdate>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    <D:propstat><D:prop><CS:getctag/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/drive/user/user1/docs/a%20b%25%23.txt</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>5</D:getcontentlength>
      <D:getcontenttype>text/plain</D:getcontenttype>
      <D:getetag>"e91bbad412cd27c0ffcb9c6031ce0e4c433f59b5"</D:getetag>
      <D:getlastmodified>Sat, 10 Oct 2026 01:45:31 GMT</D:getlastmodified>
      <D:resourcetype/>
      <D:current-user-privilege-set>
        <D:privilege><D:read/></D:privilege>
        <D:privilege><D:write-content/></D:privilege>
        <D:privilege><D:bind/></D:privilege>
      </D:current-user-privilege-set>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/drive/user/user1/docs/caf%C3%A9.txt</D:href>
    <D:status>HTTP/1.1 404 Not Found</D:status>
  </D:response>
</D:multistatus>
XML

my $e = $parse->($listing);
is(scalar @$e, 3, 'three responses');
is($e->[0]{href}, '/dav/drive/user/user1/docs', 'collection href without trailing slash');
ok($e->[0]{isCollection}, 'collection detected');
is($e->[0]{etag}, '1791596669-1-1', 'etag unquoted');
is($e->[0]{ctag}, undef, '404 propstat ignored');
is($e->[0]{created}, 1791596652, 'creationdate parsed');
is($e->[1]{href}, '/dav/drive/user/user1/docs/a b%#.txt', 'href unescaped exactly once');
ok(!$e->[1]{isCollection}, 'file');
is($e->[1]{size}, 5, 'size');
is($e->[1]{type}, 'text/plain', 'type');
is($e->[1]{modified}, 1791596731, 'getlastmodified parsed');
is_deeply([ sort @{ $e->[1]{privileges} } ], [qw(bind read write-content)], 'privileges');
ok($e->[2]{missing}, 'top-level 404 status is a removal');
is($e->[2]{href}, "/dav/drive/user/user1/docs/caf\x{e9}.txt", 'UTF-8 percent-escapes decode to characters');

# Cyrus answers a Depth-0 PROPFIND on a file with an empty multistatus.
my $empty = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:" xmlns:J="https://jmap.io/ns/filenode">\n\n};
is_deeply($parse->($empty), [], 'an empty (even unterminated) multistatus is no entries, not a crash');

# Dead properties, oc:fileid and ME:sha1hex.
my $dead = <<'XML';
<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:" xmlns:J="https://jmap.io/ns/filenode" xmlns:oc="http://owncloud.org/ns" xmlns:ME="https://www.fastmail.com/dav/">
  <D:response><D:href>/f/x</D:href><D:propstat><D:prop>
    <J:executable>1</J:executable><J:accessed>2026-10-01T00:00:00Z</J:accessed>
    <oc:fileid>00001234ocabc</oc:fileid><ME:sha1hex>aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d</ME:sha1hex>
  </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>
XML
my ($d) = @{ $parse->($dead) };
is_deeply($d->{dead}, { executable => '1', accessed => '2026-10-01T00:00:00Z' }, 'dead properties');
is($d->{fileid}, '00001234ocabc', 'oc:fileid');
is($d->{sha1}, 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d', 'ME:sha1hex');

done_testing;
