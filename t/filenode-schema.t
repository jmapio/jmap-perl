#!/usr/bin/perl
# t/filenode-schema.t
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;

my $db = JMAP::ImapDB->new('schematest');
$db->begin();
my $dbh = $db->dbh;

my ($v) = $dbh->selectrow_array('PRAGMA user_version');
is($v, 12, 'user schema is v12');

my %cols = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(jfilenodes)') };
ok($cols{$_}, "jfilenodes.$_") for qw(nodeid parentid name href nodetype etag ctag size
  type created modified accessed changed fileid fingerprint privs role executable
  isSubscribed deadprops sharewith jcreated jmodseq mtime active);

my %is = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(iserver)') };
ok($is{$_}, "iserver.$_") for qw(webdavURL webdavFeatures lastfilesync);

my %acct = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(account)') };
ok($acct{jstateFileNode}, 'account.jstateFileNode');

my %sync = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(jfilesync)') };
ok($sync{$_}, "jfilesync.$_") for qw(href token mtime);

$db->commit();
done_testing;
