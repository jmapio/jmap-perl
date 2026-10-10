#!/usr/bin/perl
# The FileNode quota: an RFC 4331 WebDAV quota as an RFC 9425 Quota object.
use strict;
use warnings;
use Test::More;
use lib '.';
use JSON::XS;
use File::Temp qw(tempdir);
BEGIN { $ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1) }
use JMAP::API;
require JMAP::ImapDB;

my $q = JMAP::API::_files_quota_to_jmap({ used => 4096, available => 104853504 }, 'user1@example.com');
is_deeply($q, {
  id => 'files:octets', resourceType => 'octets', scope => 'account', name => 'user1@example.com',
  types => ['FileNode'], used => 4096, hardLimit => 104857600,
}, 'used, and a hard limit of used plus available');
like(JSON::XS->new->canonical->encode($q), qr/"hardLimit":104857600,.*"used":4096\b/, 'numbers encode as JSON numbers');
is(JMAP::API::_files_quota_to_jmap(undef, 'x'), undef, 'no WebDAV quota, no Quota object');

# files_quota keeps the last value read for when the PROPFIND fails, so the
# files Quota does not flap destroyed/created
{
  my @answers;
  no warnings qw(redefine once);
  local *JMAP::ImapDB::backend_cmd = sub {
    my ($Self, $cmd) = @_;
    die "unexpected $cmd" unless $cmd eq 'files_quota';
    my $a = shift @answers;
    die $a->{die} if ref $a eq 'HASH' && $a->{die};
    return $a;
  };
  my $db = JMAP::ImapDB->new('quotatest');
  $db->begin();
  $db->dinsert('iserver', { username => 'u', webdavURL => 'http://dav.example/d/', webdavFeatures => encode_json({ quota => 1 }) });
  $db->commit();
  @answers = ({ die => "PROPFIND /d/ (quota): HTTP 503\n" });
  ok(!eval { $db->files_quota(); 1 }, 'a failure with nothing read yet dies');
  @answers = ({ used => 1, available => 9 }, { die => "PROPFIND /d/ (quota): HTTP 503\n" }, undef);
  is_deeply($db->files_quota(), { used => 1, available => 9 }, 'read');
  my @w;
  { local $SIG{__WARN__} = sub { push @w, @_ }; is_deeply($db->files_quota(), { used => 1, available => 9 }, 'a failure reuses the last value') }
  ok((grep { /reusing/ } @w), 'with a warning');
  is($db->files_quota(), undef, 'a server that now reports no quota: none');
}

done_testing;
