#!/usr/bin/perl
# Bogus-server defences: replay canned (bad) responses through a stubbed transport.
use strict;
use warnings;
use Test::More;
use lib '.';
use Digest::SHA qw(sha1_hex);
use JMAP::Sync::WebDAVTalk;

{
  package Stub;
  our @ISA = ('JMAP::Sync::WebDAVTalk');
  # script: coderef ($method, $path, $body, %h) -> response hashref
  sub Raw {
    my ($Self, $m, $p, $b, %h) = @_;
    push @{ $Self->{log} }, "$m $p";
    return $Self->{script}->($m, $p, $b, %h);
  }
}

sub ms { my $inner = join '', @_;
  qq{<?xml version="1.0"?><D:multistatus xmlns:D="DAV:" xmlns:J="https://jmap.io/ns/filenode">$inner</D:multistatus>} }
sub resp { my ($href, $props) = @_;
  qq{<D:response><D:href>$href</D:href><D:propstat><D:prop>$props</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>} }
sub r207 { +{ status => 207, headers => {}, content => $_[0] } }

my $root = '/r';
my $bytes = "jmap-probe\n";

# Build a stub server.  %o: etag (PUT etag), moved_etag, dead (listing carries J:probe),
# sync (status for REPORT), die_on (method that dies)
sub mk {
  my %o = @_;
  my $d = bless { log => [] }, 'Stub';
  $d->{script} = sub {
    my ($m, $p, $b, %h) = @_;
    die "boom\n" if $o{die_on} && $m eq $o{die_on};
    return { status => 201, headers => { etag => qq{"$o{etag}"} }, content => '' } if $m eq 'PUT';
    return { status => 207, headers => {}, content => ms('<D:response><D:href>x</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>') }
      if $m eq 'PROPPATCH';
    return { status => 201, headers => {}, content => '' } if $m eq 'MOVE';
    return { status => 204, headers => {}, content => '' } if $m eq 'DELETE';
    if ($m eq 'PROPFIND' && $b =~ /<D:acl/) { return { status => 403, headers => {}, content => '' } }
    if ($m eq 'PROPFIND' && $b =~ /quota/) { return { status => 404, headers => {}, content => '' } }
    if ($m eq 'PROPFIND') {
      my $moved = $d->{log} && grep { /^MOVE/ } @{ $d->{log} };
      my $name = $moved ? "$d->{name}-moved" : $d->{name};
      my $etag = $moved ? ($o{moved_etag} // $o{etag}) : $o{etag};
      return r207(ms(resp($name, qq{<D:getetag>"$etag"</D:getetag>} . ($o{dead} ? '<J:probe>x</J:probe>' : ''))));
    }
    if ($m eq 'REPORT') {
      return { status => $o{sync}, headers => {}, content => '' } if $o{sync} != 207;
      return r207(ms('<D:sync-token>tok1</D:sync-token>'));
    }
    return { status => 500, headers => {}, content => '' };
  };
  # learn the scratch name from the PUT
  my $orig = $d->{script};
  $d->{script} = sub { my ($m, $p) = @_; $d->{name} = $p if $m eq 'PUT' && !$d->{name}; $orig->(@_) };
  return $d;
}
sub probe { my $d = shift; my $f = $d->Probe($root); return $f }

# (a) dead properties: PROPPATCH 207/200 but property must read back
is(probe(mk(etag => 'zz', dead => 0))->{deadProps}, 0, 'PROPPATCH 200 but listing lacks the property: deadProps 0');
is(probe(mk(etag => 'zz', dead => 1))->{deadProps}, 1, 'property reads back: deadProps 1');

# (b) etagIsContent
is(probe(mk(etag => 'notasha'))->{etagIsContent}, 0, 'ETag not SHA-1 of bytes: 0');
my $sha = sha1_hex($bytes);
is(probe(mk(etag => $sha, moved_etag => 'changed'))->{etagIsContent}, 0, 'ETag changes on MOVE: 0');
is(probe(mk(etag => $sha))->{etagIsContent}, 1, 'ETag is content hash and survives MOVE: 1');

# (c) sync-collection refused
for my $st (400, 403) {
  my $d = mk(etag => 'zz', sync => $st);
  is($d->SyncCollection($root, ''), undef, "REPORT $st: SyncCollection undef");
  is(probe(mk(etag => 'zz', sync => $st))->{syncCollection}, 0, "REPORT $st: Probe syncCollection 0");
}
my $ok = mk(etag => 'zz', sync => 207)->SyncCollection($root, 'a<b');
is($ok->{token}, 'tok1', 'sync 207 gives a token');

# (d) scratch file always deleted
{
  my $d = mk(etag => $sha, die_on => 'PROPPATCH');
  eval { $d->Probe($root) };
  like($@, qr/boom/, 'middle-step failure is rethrown');
  ok((grep { /^DELETE \Q$d->{name}\E$/ } @{ $d->{log} }), 'scratch file still DELETEd');
}

# request URLs are UTF-8 percent-encoded
{
  my $d = JMAP::Sync::WebDAVTalk->new(url => 'http://h/dav/');
  like($d->_url("/dav/caf\x{e9}"), qr{/dav/caf%C3%A9$}, 'e-acute is %C3%A9');
  my $u = eval { $d->_url("/dav/\x{4e2d}") };
  like($u, qr{/dav/%E4%B8%AD$}, 'non-Latin-1 does not die');
}

done_testing;
