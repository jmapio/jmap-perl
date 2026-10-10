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
    return $Self->{script}->($m, $p, $b // '', %h);
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
  my %o = (sync => 207, @_);
  my $d = bless { log => [] }, 'Stub';
  $d->{script} = sub {
    my ($m, $p, $b, %h) = @_;
    die "boom\n" if $o{die_on} && $m eq $o{die_on};
    return { status => 201, headers => { etag => qq{"$o{etag}"} }, content => '' } if $m eq 'PUT';
    return { status => 207, headers => {}, content => ms('<D:response><D:href>x</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>') }
      if $m eq 'PROPPATCH';
    return { status => 201, headers => {}, content => '' } if $m eq 'MKCOL' && defined $o{shell};
    return { status => ($o{shell} ? 207 : 404), headers => {}, content => '' } if $m eq 'PROPFIND' && $p =~ m{-d/\z};
    return { status => 201, headers => {}, content => '' } if $m eq 'MOVE';
    return { status => 204, headers => {}, content => '' } if $m eq 'DELETE';
    if ($m eq 'PROPFIND' && $b =~ /<D:acl/) { return { status => 403, headers => {}, content => '' } }
    if ($m eq 'PROPFIND' && $b =~ /quota/) { return { status => 404, headers => {}, content => '' } }
    if ($m eq 'PROPFIND') {
      my $moved = $d->{log} && grep { /^MOVE/ } @{ $d->{log} };
      return r207(ms(resp("$root/", '<D:resourcetype><D:collection/></D:resourcetype>'))) unless $d->{name};
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

# (c2) a collection MOVE that leaves an empty collection behind (Cyrus)
{
  my $d = mk(etag => 'zz', shell => 1);
  is(probe($d)->{moveLeavesEmpty}, 1, 'the old name still answers after a collection MOVE: moveLeavesEmpty 1');
  ok((grep { m{^DELETE .*-d-moved/\z} } @{ $d->{log} }) && (grep { m{^DELETE .*-d/\z} } @{ $d->{log} }), 'and the probe tidies both');
  is(probe(mk(etag => 'zz', shell => 0))->{moveLeavesEmpty}, 0, 'gone after the MOVE: moveLeavesEmpty 0');
  ok(!exists probe(mk(etag => 'zz'))->{moveLeavesEmpty}, 'no MKCOL: unknown');
}

# (d) scratch file always deleted
{
  my $d = mk(etag => $sha, die_on => 'PROPPATCH');
  eval { $d->Probe($root) };
  like($@, qr/boom/, 'middle-step failure is rethrown');
  ok((grep { /^DELETE \Q$d->{name}\E$/ } @{ $d->{log} }), 'scratch file still DELETEd');
}

# If-Match goes out only for a strong ETag (RFC 7232 S3.1: the strong
# comparison, which a weak tag never passes), on GET, PUT and DELETE alike
{
  my %sent;
  my $d = bless { log => [] }, 'Stub';
  $d->{script} = sub { my ($m, $p, $b, %h) = @_; $sent{$m} = $h{'If-Match'}; return { status => 200, headers => { etag => 'W/"new"' }, content => '' } };
  $d->Get('/f', if_match => 'abc');
  $d->Put('/f', 'x', if_match => 'abc');
  $d->Delete('/f', if_match => 'abc');
  is_deeply(\%sent, { GET => '"abc"', PUT => '"abc"', DELETE => '"abc"' }, 'a strong ETag: If-Match on each');
  %sent = ();
  is($d->Get('/f', if_match => 'W/abc')->{etag}, 'W/new', 'a weak ETag in the answer keeps its mark');
  $d->Put('/f', 'x', if_match => 'W/abc');
  $d->Delete('/f', if_match => 'W/abc');
  is_deeply(\%sent, { GET => undef, PUT => undef, DELETE => undef }, 'a weak ETag: no If-Match at all');
  $d->Delete('/f');
  is($sent{DELETE}, undef, 'no ETag: none');
}

# request URLs are UTF-8 percent-encoded
{
  my $d = JMAP::Sync::WebDAVTalk->new(url => 'http://h/dav/');
  like($d->_url("/dav/caf\x{e9}"), qr{/dav/caf%C3%A9$}, 'e-acute is %C3%A9');
  my $u = eval { $d->_url("/dav/\x{4e2d}") };
  like($u, qr{/dav/%E4%B8%AD$}, 'non-Latin-1 does not die');
}

# --- RFC 3744 ACLs (Task 10)
my $CY = 'http://cyrusimap.org/ns/';
# a Cyrus-like DAV:acl, with every principal form RFC 3744 S5.5.1 allows
my $ACL = qq{<D:acl>}
  . q{<D:ace><D:principal><D:self/></D:principal><D:grant><D:privilege><D:all/></D:privilege></D:grant></D:ace>}
  . q{<D:ace><D:principal><D:href>/dav/principals/user/user2/</D:href></D:principal><D:grant><D:privilege><D:read/></D:privilege><D:privilege><CY:admin/></D:privilege></D:grant></D:ace>}
  . q{<D:ace><D:principal><D:href>http://h/dav/principals/user/caf%C3%A9</D:href></D:principal><D:deny><D:privilege><D:write/></D:privilege></D:deny></D:ace>}
  . q{<D:ace><D:principal><D:property><D:owner/></D:property></D:principal><D:grant><D:privilege><D:read-acl/></D:privilege></D:grant><D:protected/></D:ace>}
  . q{<D:ace><D:invert><D:principal><D:authenticated/></D:principal></D:invert><D:deny><D:privilege><D:read/></D:privilege></D:deny></D:ace>}
  . q{<D:ace><D:principal><D:all/></D:principal><D:grant><D:privilege><D:read/></D:privilege></D:grant><D:inherited><D:href>/dav/drive/user/u/</D:href></D:inherited></D:ace>}
  . q{</D:acl>};
# (Cyrus describes each privilege with xml:lang, which Net::DAVTalk's parser chokes on)
my $PRIVSET = q{<D:supported-privilege-set><D:supported-privilege><D:privilege><D:all/></D:privilege><D:description xml:lang="en">Any operation</D:description>}
  . q{<D:supported-privilege><D:privilege><D:read/></D:privilege></D:supported-privilege>}
  . q{<D:supported-privilege><D:privilege><D:write/></D:privilege>}
  .   q{<D:supported-privilege><D:privilege><D:bind/></D:privilege><D:supported-privilege><D:privilege><D:write-content/></D:privilege></D:supported-privilege></D:supported-privilege>}
  .   q{<D:supported-privilege><D:privilege><D:unbind/></D:privilege></D:supported-privilege></D:supported-privilege>}
  . q{<D:supported-privilege><D:privilege><CY:admin/></D:privilege>}
  .   q{<D:supported-privilege><D:privilege><D:write-acl/></D:privilege><D:abstract/></D:supported-privilege></D:supported-privilege>}
  . q{</D:supported-privilege></D:supported-privilege-set>};
sub acl_ms { my ($href, $props) = @_;
  qq{<?xml version="1.0"?><D:multistatus xmlns:D="DAV:" xmlns:CY="$CY">} . resp($href, $props) . '</D:multistatus>' }
my @EXPECT_ACES = (
  { principal => 'self', invert => 0, grant => ['all'], deny => [], inherited => 0, protected => 0 },
  { principal => '/dav/principals/user/user2/', href => '/dav/principals/user/user2/', invert => 0, grant => ['read', "{$CY}admin"], deny => [], inherited => 0, protected => 0 },
  { principal => "/dav/principals/user/caf\x{e9}/", href => 'http://h/dav/principals/user/caf%C3%A9', invert => 0, grant => [], deny => ['write'], inherited => 0, protected => 0 },
  { principal => 'property', property => '{DAV:}owner', invert => 0, grant => ['read-acl'], deny => [], inherited => 0, protected => 1 },
  { principal => 'authenticated', invert => 1, grant => [], deny => ['read'], inherited => 0, protected => 0 },
  { principal => 'all', invert => 0, grant => ['read'], deny => [], inherited => 1, protected => 0 },
);
{
  my @reqs;
  my $d = bless { log => [] }, 'Stub';
  $d->{script} = sub {
    my ($m, $p, $b) = @_;
    push @reqs, [$m, $p, $b];
    if ($m eq 'PROPFIND' && $b =~ /<D:acl\/>/) {
      # Cyrus answers a Depth-0 PROPFIND on a collection with its members too
      return r207(qq{<?xml version="1.0"?><D:multistatus xmlns:D="DAV:" xmlns:CY="$CY">}
        . resp('/dav/drive/user/u/d/f.txt', '<D:acl/>')
        . resp('/dav/drive/user/u/d/', "$ACL<D:owner><D:href>/dav/principals/user/u/</D:href></D:owner>$PRIVSET"
               . '<D:principal-collection-set><D:href>/dav/principals/user/</D:href></D:principal-collection-set>')
        . '</D:multistatus>');
    }
    return { status => 403, headers => {}, content => '<?xml version="1.0"?><D:error xmlns:D="DAV:"><D:recognized-principal/></D:error>' }
      if $m eq 'ACL';
    return { status => 500, headers => {}, content => '' };
  };
  my $info = $d->AclInfo('/dav/drive/user/u/d/');
  is_deeply($info->{aces}, \@EXPECT_ACES, 'AclInfo: every principal form, deny, invert, protected, inherited, foreign privileges')
    or diag explain $info;
  is($info->{owner}, '/dav/principals/user/u/', 'the owner');
  is_deeply($info->{principalCollections}, ['/dav/principals/user/'], 'the principal collections');
  is_deeply($info->{privileges}{'write-acl'}, { parent => "{$CY}admin", abstract => 1 }, 'write-acl: abstract, under the server\'s admin');
  is_deeply($info->{privileges}{'write-content'}, { parent => 'bind', abstract => 0 }, 'write-content under bind');
  is($info->{privileges}{all}{parent}, undef, 'all is the top');
  is_deeply($d->GetAcl('/dav/drive/user/u/d/'), \@EXPECT_ACES, 'GetAcl: the ACEs');

  # SetAcl writes back what it read: inherited and protected ACEs are left
  # out (RFC 3744 S8.1), every other one round-trips
  my $r = $d->SetAcl('/dav/drive/user/u/d/', \@EXPECT_ACES);
  is_deeply($r, { status => 403, error => 'recognized-principal' }, 'SetAcl: status and the DAV:error precondition');
  my $body = $reqs[-1][2];
  my $back = JMAP::Sync::WebDAVTalk::parse_aces(Net::DAVTalk::XMLParser::xmlToHash($body));
  is_deeply($back, [ grep { !$_->{inherited} && !$_->{protected} } @EXPECT_ACES ], 'the ACL request round-trips') or diag $body;
  like($body, qr{<D:href>http://h/dav/principals/user/caf%C3%A9</D:href>}, 'a kept ACE goes back with the href it came with');
  my $x2 = JMAP::Sync::WebDAVTalk::acl_xml([ { principal => '/p/a/b/', href => '/p/a%2Fb/', grant => ['read'] } ]);
  like($x2, qr{<D:href>/p/a%2Fb/</D:href>}, 'a %2F is not decoded into a new segment');
  $x2 = JMAP::Sync::WebDAVTalk::acl_xml([ { principal => '/p/x/', href => '/p/<x>"&/', grant => ['read'] } ]);
  like($x2, qr{<D:href>/p/&lt;x&gt;"&amp;/</D:href>}, 'and it is still XML-escaped');

  # nothing from a client reaches the XML raw
  my $x = JMAP::Sync::WebDAVTalk::acl_xml([ { principal => '/dav/principals/user/a"b<c&d>e/', grant => ['read'] } ]);
  like($x, qr{<D:href>/dav/principals/user/a%22b%3Cc%26d%3Ee/</D:href>}, 'a hostile user id is percent-encoded');
  ok(eval { Net::DAVTalk::XMLParser::xmlToHash($x); 1 }, 'and the body is well-formed XML');
  $x = JMAP::Sync::WebDAVTalk::acl_xml([ { principal => '/p/a b/', grant => [qq{{urn:x"y}priv}] } ]);
  like($x, qr{<X:priv xmlns:X="urn:x&quot;y"/>}, 'a foreign namespace is an escaped attribute');
  for my $bad ([ principal => 'all"/><D:x', grant => ['read'] ], [ principal => 'self', grant => ['read/><D:all'] ],
               [ principal => 'property', property => '<x>', grant => ['read'] ], [ principal => 'self', grant => [] ],
               [ principal => 'self', grant => ['{urn:x}a b'] ]) {
    ok(!eval { JMAP::Sync::WebDAVTalk::acl_xml([ { @$bad } ]); 1 }, "refused: @$bad[0..1] / @{ $bad->[-1] || [] }");
  }
}
# parse_multistatus carries acl and owner when a listing asks for them
{
  my $e = JMAP::Sync::WebDAVTalk::parse_multistatus(acl_ms('/dav/drive/user/u/d/',
    "<D:resourcetype><D:collection/></D:resourcetype>$ACL<D:owner><D:href>/dav/principals/user/u/</D:href></D:owner>"));
  is_deeply($e->[0]{acl}, \@EXPECT_ACES, 'a listing entry carries its ACL');
  is($e->[0]{owner}, '/dav/principals/user/u/', 'and its owner');
  my $d = bless { log => [] }, 'Stub';
  my $body;
  $d->{script} = sub { $body = $_[2]; return r207(acl_ms('/x/', '')) };
  $d->PropFind('/x/', 1);
  unlike($body, qr/<D:acl/, 'a plain listing does not ask for the ACL');
  $d->PropFind('/x/', 1, { acl => 1 });
  like($body, qr{<D:acl/><D:owner/></D:prop>}, 'with { acl => 1 } it does');
}
# Probe: ACL support is the "access-control" class (RFC 3744 S7.2) AND a
# DAV:acl that really reads back
for my $case ([ '1, 2, 3, access-control', 1 ], [ '1, 2, 3', 0 ], [ '1, access-control-ish', 0 ]) {
  my ($dav, $want) = @$case;
  my $d = mk(etag => 'zz');
  my $orig = $d->{script};
  $d->{script} = sub {
    my ($m, $p, $b) = @_;
    return { status => 200, headers => { dav => $dav }, content => '' } if $m eq 'OPTIONS';
    return r207(acl_ms("$root/", "$ACL<D:owner><D:href>/dav/principals/user/u/</D:href></D:owner>$PRIVSET"
                       . '<D:principal-collection-set><D:href>/dav/principals/group/</D:href><D:href>/dav/principals/user/</D:href></D:principal-collection-set>'))
      if $m eq 'PROPFIND' && $b =~ /<D:acl\/>/;
    return $orig->(@_);
  };
  my $f = probe($d);
  is($f->{acl}, $want, "DAV: $dav -> acl $want");
  next unless $want;
  is($f->{principalBase}, '/dav/principals/user/', 'principalBase: the collection holding the owner');
  is($f->{privileges}{'write-acl'}{abstract}, 1, 'the privilege tree is kept');
}
{
  # access-control advertised, but DAV:acl is not readable (404 propstat)
  my $d = mk(etag => 'zz');
  my $orig = $d->{script};
  $d->{script} = sub {
    my ($m, $p, $b) = @_;
    return { status => 200, headers => { dav => '1, access-control' }, content => '' } if $m eq 'OPTIONS';
    return r207(qq{<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>$root/</D:href><D:propstat><D:prop><D:acl/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response></D:multistatus>})
      if $m eq 'PROPFIND' && $b =~ /<D:acl\/>/;
    return $orig->(@_);
  };
  is(probe($d)->{acl}, 0, 'access-control claimed but DAV:acl unreadable: acl 0');
}

# xml:* attributes are dropped from start tags only, never from text (M6)
{
  my $e = JMAP::Sync::WebDAVTalk::parse_multistatus(
    qq{<?xml version="1.0"?><D:multistatus xmlns:D="DAV:" xmlns:J="https://jmap.io/ns/filenode"><D:response xml:lang="en">}
    . q{<D:href>/r/f</D:href><D:propstat><D:prop><J:type xml:space='preserve'>text/x; xml:a="b"</J:type></D:prop>}
    . q{<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>});
  is($e->[0]{dead}{type}, 'text/x; xml:a="b"', 'a dead value containing xml:a="b" survives; the attributes go');
}

# principal_base (I2): the collection the owner is DIRECTLY below, else the owner's parent
is(JMAP::Sync::WebDAVTalk::principal_base('/principals/users/u/', [ '/principals/', '/principals/users/' ]), '/principals/users/',
   'the collection directly above the owner, not merely a prefix of it');
is(JMAP::Sync::WebDAVTalk::principal_base('/principals/users/u/', ['/principals/']), '/principals/users/',
   'no collection directly above: the owner\'s parent');
is(JMAP::Sync::WebDAVTalk::principal_base(undef, ['/principals/']), undef, 'no owner: no base');
{
  my $d = mk(etag => 'zz');
  my $orig = $d->{script};
  $d->{script} = sub {
    my ($m, $p, $b) = @_;
    return { status => 200, headers => { dav => '1, access-control' }, content => '' } if $m eq 'OPTIONS';
    return r207(acl_ms("$root/", "$ACL<D:owner><D:href>/principals/users/u/</D:href></D:owner>"
                       . '<D:principal-collection-set><D:href>/principals/</D:href></D:principal-collection-set>'))
      if $m eq 'PROPFIND' && $b =~ /<D:acl\/>/;
    return $orig->(@_);
  };
  is(probe($d)->{principalBase}, '/principals/users/', 'Probe: /principals/ is not where users are; /principals/users/ is');
}

# RFC 4331 quota: Quota() reads the collection's own response (a server may
# list members too) and wants both properties.
{
  my $members = resp('/r/', '<D:quota-used-bytes>10</D:quota-used-bytes><D:quota-available-bytes>90</D:quota-available-bytes>')
              . resp('/r/f', '<D:quota-used-bytes>1</D:quota-used-bytes><D:quota-available-bytes>2</D:quota-available-bytes>');
  my $q = sub { my $c = shift; my $d = bless { log => [], script => sub { $c->(@_) } }, 'Stub'; $d->Quota('/r/') };
  is_deeply($q->(sub { r207(ms($members)) }), { used => 10, available => 90 }, 'Quota: the collection\'s own values');
  is($q->(sub { r207(ms(resp('/r/', '<D:quota-used-bytes>10</D:quota-used-bytes>'))) }), undef,
     'Quota: no quota-available-bytes, no quota');
  ok(!eval { $q->(sub { +{ status => 503, headers => {}, content => '' } }); 1 }, 'Quota: a failed PROPFIND dies (not "no quota")');
}

# Delete with If-Match sends the ETag quoted
{
  my %h;
  my $d = bless { log => [], script => sub { my ($m, $p, $b, %hh) = @_; %h = %hh; +{ status => 412, headers => {}, content => '' } } }, 'Stub';
  is($d->Delete('/r/f', if_match => 'abc'), 412, 'Delete returns the status');
  is($h{'If-Match'}, '"abc"', 'Delete sends If-Match');
  $d->Delete('/r/f');
  ok(!exists $h{'If-Match'}, 'and none without if_match');
}

# no WebDAV collection at the root (a server without WebDAV): Probe dies, so
# nothing is kept and FileNode is not advertised
{
  my $d = bless { log => [], script => sub { +{ status => 404, headers => {}, content => '' } } }, 'Stub';
  ok(!eval { $d->Probe($root); 1 }, 'Probe dies when the root is not a WebDAV collection');
  like($@, qr/not a WebDAV collection/, 'saying so');
  ok(!grep({ /^PUT/ } @{ $d->{log} }), 'and writes nothing');
}

done_testing;
