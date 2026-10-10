#!/usr/bin/perl
# The FileNode account capability (draft-ietf-jmap-filenode S2.1): only for an
# account with a WebDAV home, with webWriteUrlTemplate under the proxy's BASEURL.
use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Capabilities qw(imap_account_capabilities);

my $urn = 'urn:ietf:params:jmap:filenode';
ok(!exists imap_account_capabilities({})->{$urn}, 'no webdavURL: no capability');

my $c = imap_account_capabilities({ webdavURL => 'http://dav/drive/', baseurl => 'https://p.example/' })->{$urn};
ok($c, 'webdavURL: capability');
is($c->{maxSizeFileNodeName}, 255, 'maxSizeFileNodeName');
ok(!$c->{mayCreateTopLevelFileNode}, 'mayCreateTopLevelFileNode false');
is($c->{webWriteUrlTemplate}, 'https://p.example/filenode/{accountId}/{id}', 'webWriteUrlTemplate from baseurl');

{
  local $ENV{BASEURL} = 'https://env.example';
  is(imap_account_capabilities({ webdavURL => 'x' })->{$urn}{webWriteUrlTemplate},
     'https://env.example/filenode/{accountId}/{id}', 'a worker without baseurl falls back to BASEURL');
}

done_testing;
