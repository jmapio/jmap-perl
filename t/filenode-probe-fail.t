#!/usr/bin/perl
# An account whose WebDAV Probe fails (no WebDAV at webdavURL) keeps no
# webdavFeatures and so gets no FileNode capability; once a Probe works it does.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
use JMAP::Capabilities qw(imap_account_capabilities);

my $urn = 'urn:ietf:params:jmap:filenode';
my $probe_ok = 0;
{
  no warnings qw(redefine once);
  *JMAP::ImapDB::backend_cmd = sub {
    my ($Self, $cmd) = @_;
    die "unexpected $cmd" unless $cmd eq 'files_probe';
    die "Probe: /dav/drive/user/u/ is not a WebDAV collection (PROPFIND: HTTP 404)\n" unless $probe_ok;
    return { acl => 0, deadProps => 0, etagIsContent => 0, quota => 0, syncCollection => 0 };
  };
}

my $db = JMAP::ImapDB->new('probetest');
$db->begin();
$db->dinsert('iserver', { username => 'u', webdavURL => 'http://dav.example/dav/drive/user/u/' });
$db->commit();
my $iserver = sub { $db->begin(); my $r = $db->dgetone('iserver'); $db->commit(); return $r };

{
  local $SIG{__WARN__} = sub {};
  is_deeply($db->filenode_features(), {}, 'a failed Probe: no features');
}
is($iserver->()->{webdavFeatures}, undef, 'and nothing is kept');
ok(!JMAP::Capabilities::filenode_ok($iserver->()), 'filenode_ok is false');
ok(!exists imap_account_capabilities($iserver->())->{$urn}, 'no FileNode capability');

$probe_ok = 1;
ok(scalar %{ $db->filenode_features() }, 'a Probe that works: features');
ok(JMAP::Capabilities::filenode_ok($iserver->()), 'filenode_ok is true');
ok(exists imap_account_capabilities($iserver->())->{$urn}, 'the FileNode capability');

done_testing;
