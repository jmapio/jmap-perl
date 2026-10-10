#!/usr/bin/perl
# The FileNode account capability (draft-ietf-jmap-filenode S2.1): only for an
# account with a WebDAV home, with webWriteUrlTemplate under the proxy's BASEURL.
use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Capabilities qw(imap_account_capabilities);

my $urn = 'urn:ietf:params:jmap:filenode';
ok(!exists imap_account_capabilities({})->{$urn}, 'no webdavURL: no capability');

# FileNode only once a Probe of the WebDAV server has worked
ok(!exists imap_account_capabilities({ webdavURL => 'http://dav/drive/' })->{$urn},
   'webdavURL but never probed (an iserver row without webdavFeatures): no capability');
ok(!exists imap_account_capabilities({ webdavURL => 'http://dav/drive/', webdavFeatures => '{}' })->{$urn},
   'an empty feature set: no capability');
ok(!exists imap_account_capabilities({ webdavURL => 'http://dav/drive/', filenode => 0 })->{$urn},
   'the parent\'s account details say the Probe has not worked: no capability');
ok(exists imap_account_capabilities({ webdavURL => 'http://dav/drive/', webdavFeatures => '{"acl":0}' })->{$urn},
   'a stored Probe result: capability');

my $c = imap_account_capabilities({ webdavURL => 'http://dav/drive/', filenode => 1, baseurl => 'https://p.example/', accountid => 'alice' })->{$urn};
ok($c, 'webdavURL and a working Probe: capability');
is($c->{maxSizeFileNodeName}, 255, 'maxSizeFileNodeName');
ok(!$c->{mayCreateTopLevelFileNode}, 'mayCreateTopLevelFileNode false');
# draft S2.1: "The available variable is {id}" -- the account is expanded
is($c->{webWriteUrlTemplate}, 'https://p.example/filenode/alice/{id}', 'webWriteUrlTemplate from baseurl, with the account expanded');
is_deeply([ $c->{webWriteUrlTemplate} =~ /\{([^}]*)\}/g ], ['id'], 'the only template variable is {id}');

{
  local $ENV{BASEURL} = 'https://env.example';
  is(imap_account_capabilities({ webdavURL => 'x', filenode => 1, accountid => 'bob' })->{$urn}{webWriteUrlTemplate},
     'https://env.example/filenode/bob/{id}', 'a worker without baseurl falls back to BASEURL');
}
is(imap_account_capabilities({ webdavURL => 'x', filenode => 1 })->{$urn}{webWriteUrlTemplate}, undef,
   'no accountid to expand: no template (null: no direct writes)');

done_testing;
