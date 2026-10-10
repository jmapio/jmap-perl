package JMAP::Sync::WebDAVTalk;

# WebDAV (RFC 4918) for FileNode: requests and multistatus normalisation.
# Protocol only -- no DB.  Paths are absolute and URI-unescaped; request_url
# (Net::DAVTalk) escapes each segment exactly once.

use strict;
use warnings;
use parent 'Net::DAVTalk';
use Net::DAVTalk::XMLParser;
use Encode qw(decode_utf8 encode_utf8);
use URI::Escape qw(uri_unescape uri_escape_utf8);
use HTTP::Date qw(str2time);
use Digest::SHA qw(sha1_hex);
use Data::UUID::LibUUID qw(new_uuid_string);

our $NS_J = 'https://jmap.io/ns/filenode';
my $D = '{DAV:}';

sub _list { my $v = shift; return () unless defined $v; return ref $v eq 'ARRAY' ? @$v : ($v) }
sub _text { my $v = shift; return ref $v eq 'HASH' ? $v->{content} : $v }

sub _unescape_href {
  my $href = shift // '';
  $href =~ s{^https?://[^/]+}{};
  my $path = uri_unescape($href);
  $path = eval { decode_utf8($path, Encode::FB_CROAK) } // $path;
  $path =~ s{/+$}{} if length $path > 1;
  return $path;
}

# Net::DAVTalk::XMLParser dies on the predefined "xml" prefix ("Unknown
# namespace xml"), and Cyrus puts xml:lang on every DAV:description in a
# supported-privilege-set.  Nothing here reads xml:* attributes: drop them
# -- inside start tags only, so text (a dead property's value) is untouched.
# Text cannot hold a raw "<", so a start tag is found from its "<".
my $XML_ATTR = qr/\sxml:[A-Za-z_][\w.-]*\s*=\s*(?:"[^"]*"|'[^']*')/;
sub _xml_hash {
  my $xml = shift;
  $xml =~ s{(<[A-Za-z_](?:[^<>"']|"[^"]*"|'[^']*')*>)}{ my $t = $1; $t =~ s/$XML_ATTR//g; $t }ge;
  return xmlToHash($xml);
}

# RFC 4918 S14.16: a multistatus of responses.  Returns normalised entries.
sub parse_multistatus {
  my ($xml) = @_;
  return [] unless defined $xml && $xml =~ /<[^?!]/;
  my $tree = eval { _xml_hash($xml) };
  return [] unless $tree;
  my @entries;
  for my $resp (_list($tree->{"${D}response"})) {
    my %e = (href => _unescape_href(_text($resp->{"${D}href"})), dead => {});
    my $topstatus = _text($resp->{"${D}status"});
    if ($topstatus && $topstatus =~ / 404 /) {
      $e{missing} = 1;
      push @entries, \%e;
      next;
    }
    for my $ps (_list($resp->{"${D}propstat"})) {
      my $status = _text($ps->{"${D}status"}) // '';
      next unless $status =~ / 2\d\d /;
      my $prop = $ps->{"${D}prop"} || {};
      for my $key (keys %$prop) {
        my $val = $prop->{$key};
        if    ($key eq "${D}getetag")            { ($e{etag} = _text($val) // '') =~ s/^(?:W\/)?"|"$//g }
        elsif ($key eq '{http://calendarserver.org/ns/}getctag') { $e{ctag} = _text($val) }
        elsif ($key eq "${D}getcontentlength")   { my $t = _text($val); $e{size} = (defined $t && length $t) ? $t + 0 : undef }
        elsif ($key eq "${D}getcontenttype")     { my $t = _text($val); $e{type} = (defined $t && length $t) ? $t : undef }
        elsif ($key eq "${D}getlastmodified")    { $e{modified} = str2time(_text($val) // '') }
        elsif ($key eq "${D}creationdate")       { $e{created} = str2time(_text($val) // '') }
        elsif ($key eq "${D}resourcetype")       { $e{isCollection} = (ref $val eq 'HASH' && exists $val->{"${D}collection"}) ? 1 : 0 }
        elsif ($key eq '{http://owncloud.org/ns}fileid' || $key eq "${D}resource-id") {
          my $t = $key eq "${D}resource-id" ? _text($val->{"${D}href"}) : _text($val);
          $e{fileid} = $t if defined $t && length $t;
        }
        elsif ($key eq '{https://www.fastmail.com/dav/}sha1hex') { $e{sha1} = lc(_text($val) // '') || undef }
        elsif ($key eq "${D}current-user-privilege-set") {
          $e{privileges} = [ map { my $p = $_; map { s/^\{DAV:\}//r } grep { /^\{DAV:\}/ } keys %$p }
                             map { _list($_) } $val->{"${D}privilege"} ];
        }
        elsif ($key eq "${D}quota-used-bytes" || $key eq "${D}quota-available-bytes") {
          # RFC 4331 S3, S4: unsigned integers; anything else is ignored
          my $t = _text($val);
          $e{$key =~ /used/ ? 'quotaUsed' : 'quotaAvailable'} = $t + 0 if defined $t && $t =~ /\A\s*\d+\s*\z/;
        }
        elsif ($key eq "${D}acl")   { $e{acl} = parse_aces($val) }
        elsif ($key eq "${D}owner") { my $o = ref $val eq 'HASH' ? _href_path($val->{"${D}href"}) : undef; $e{owner} = $o if defined $o }
        elsif ($key =~ /^\{\Q$NS_J\E\}(.+)$/) { $e{dead}{$1} = _text($val) }
      }
    }
    $e{isCollection} //= 0;
    push @entries, \%e;
  }
  return \@entries;
}

my $PROPFIND_BODY = <<"XML";
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/" xmlns:J="$NS_J" xmlns:oc="http://owncloud.org/ns" xmlns:ME="https://www.fastmail.com/dav/">
  <D:prop>
    <D:resourcetype/><D:getetag/><D:getcontentlength/><D:getcontenttype/>
    <D:getlastmodified/><D:creationdate/><D:resource-id/><CS:getctag/>
    <D:current-user-privilege-set/><oc:fileid/><ME:sha1hex/>
    <J:executable/><J:accessed/><J:created/><J:modified/><J:isSubscribed/><J:role/><J:type/>
  </D:prop>
</D:propfind>
XML

sub Raw {
  my ($Self, $method, $path, $body, %headers) = @_;
  $headers{Authorization} = $Self->auth_header() if $Self->{user};
  my $res = $Self->ua->request($method, $Self->_url($path), {
    headers => \%headers,
    (defined $body ? (content => $body) : ()),
  });
  return { status => $res->{status}, headers => $res->{headers} || {}, content => $res->{content} };
}

sub _xml { my ($Self, $method, $path, $xml, %h) = @_;
  return $Self->Raw($method, $path, encode_utf8($xml), 'Content-Type' => 'application/xml; charset=utf-8', %h) }

# With { acl => 1 } each entry also carries its DAV:acl (acl, as parse_aces
# gives it) and DAV:owner (owner, an href path): Cyrus answers both in a
# Depth-1 listing, so a sync learns every collection's sharing for free.
sub PropFind {
  my ($Self, $path, $depth, $o) = @_;
  my $body = $PROPFIND_BODY;
  $body =~ s{</D:prop>}{<D:acl/><D:owner/></D:prop>} if ref $o eq 'HASH' && $o->{acl};
  my $res = $Self->_xml('PROPFIND', $path, $body, Depth => $depth // 1);
  die "PROPFIND $path: HTTP $res->{status}\n" unless $res->{status} == 207;
  return parse_multistatus($res->{content});
}

# RFC 4331: the quota covering $path, as { used, available } (bytes), or
# undef when the server reports no quota there.  A Depth-0 PROPFIND of just
# these two properties: they are not in every listing, because a server may
# work the quota out afresh for every resource it lists.
sub Quota {
  my ($Self, $path) = @_;
  my $res = $Self->_xml('PROPFIND', $path,
    qq{<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop>}
    . '<D:quota-used-bytes/><D:quota-available-bytes/></D:prop></D:propfind>', Depth => 0);
  return undef unless $res->{status} == 207;
  (my $want = $path) =~ s{/+\z}{};
  my @e = @{ parse_multistatus($res->{content}) };
  my ($e) = grep { $_->{href} eq $want } @e;
  $e //= $e[0] if @e == 1;
  return undef unless $e && defined $e->{quotaUsed} && defined $e->{quotaAvailable};
  return { used => $e->{quotaUsed}, available => $e->{quotaAvailable} };
}

sub SyncCollection {
  my ($Self, $path, $token) = @_;
  my $body = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:sync-collection xmlns:D="DAV:">}
           . '<D:sync-token>' . _xesc($token) . '</D:sync-token><D:sync-level>1</D:sync-level>'
           . ($PROPFIND_BODY =~ /(<D:prop>.*<\/D:prop>)/s)[0] . '</D:sync-collection>';
  $body =~ s/<D:sync-collection xmlns:D="DAV:">/<D:sync-collection xmlns:D="DAV:" xmlns:CS="http:\/\/calendarserver.org\/ns\/" xmlns:J="$NS_J" xmlns:oc="http:\/\/owncloud.org\/ns" xmlns:ME="https:\/\/www.fastmail.com\/dav\/">/;
  my $res = $Self->_xml('REPORT', $path, $body, Depth => 1);
  return undef unless $res->{status} == 207;
  my ($tok) = ($res->{content} // '') =~ m{<(?:\w+:)?sync-token>([^<]*)</(?:\w+:)?sync-token>};
  return undef unless defined $tok;
  return { entries => parse_multistatus($res->{content}), token => $tok };
}

sub Get {
  my ($Self, $path, %o) = @_;
  my $res = $Self->Raw('GET', $path, undef, ($o{if_match} ? ('If-Match' => qq{"$o{if_match}"}) : ()));
  (my $etag = $res->{headers}{etag} // '') =~ s/^(?:W\/)?"|"$//g;
  return { status => $res->{status}, content => $res->{content},
           type => $res->{headers}{'content-type'}, etag => $etag || undef };
}

sub Put {
  my ($Self, $path, $bytes, %o) = @_;
  my %h = ('Content-Type' => $o{type} || 'application/octet-stream');
  $h{'If-Match'} = qq{"$o{if_match}"} if $o{if_match};
  $h{'If-None-Match'} = '*' if $o{if_none_match};
  my $res = $Self->Raw('PUT', $path, $bytes, %h);
  (my $etag = $res->{headers}{etag} // '') =~ s/^(?:W\/)?"|"$//g;
  return { status => $res->{status}, etag => $etag || undef };
}

sub Mkcol  { $_[0]->Raw('MKCOL', "$_[1]/")->{status} }
sub Delete { $_[0]->Raw('DELETE', $_[1])->{status} }
sub _url   { my ($Self, $path) = @_; return $Self->request_url(encode_utf8($path)) }
sub _dest  { my ($Self, $path) = @_; return $Self->_url($path) }
sub Move {
  my ($Self, $from, $to, %o) = @_;
  return $Self->Raw('MOVE', $from, undef, Destination => $Self->_dest($to), Overwrite => ($o{overwrite} ? 'T' : 'F'))->{status};
}
sub Copy {
  my ($Self, $from, $to, %o) = @_;
  return $Self->Raw('COPY', $from, undef, Destination => $Self->_dest($to), Overwrite => ($o{overwrite} ? 'T' : 'F'), Depth => 'infinity')->{status};
}

sub _xesc { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s }

sub PropPatch {
  my ($Self, $path, $props) = @_;
  my (@set, @rm);
  for my $k (sort keys %$props) {
    if (defined $props->{$k}) { push @set, "<J:$k>" . _xesc($props->{$k}) . "</J:$k>" }
    else                      { push @rm, "<J:$k/>" }
  }
  my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:propertyupdate xmlns:D="DAV:" xmlns:J="$NS_J">}
          . (@set ? '<D:set><D:prop>' . join('', @set) . '</D:prop></D:set>' : '')
          . (@rm  ? '<D:remove><D:prop>' . join('', @rm) . '</D:prop></D:remove>' : '')
          . '</D:propertyupdate>';
  my $res = $Self->_xml('PROPPATCH', $path, $xml);
  return 0 unless $res->{status} == 207;
  return (($res->{content} // '') =~ m{<(?:\w+:)?status>HTTP/1\.1 (?!2)\d\d\d}) ? 0 : 1;
}

# --- RFC 3744 access control.  An ACE is
#   { principal => '/principals/user/x/' (an href, unescaped, with a
#                  trailing "/") | 'all' | 'authenticated' |
#                  'unauthenticated' | 'self' (DAV: principals, bare) |
#                  'property' (with property => '{ns}name'),
#     invert => 0|1, grant => [...], deny => [...],
#     inherited => 0|1, protected => 0|1 }
# Privileges are named bare in DAV: ('read') and in Clark notation in any
# other namespace ('{http://cyrusimap.org/ns/}admin'), so an ACL read back
# can be written back without losing a server's own privileges.

my $XMLNS = '{http://www.w3.org/2000/xmlns/}';
sub _clark { my $k = shift; return $k =~ /^\{DAV:\}(.+)\z/s ? $1 : $k }
sub _elements { my $h = shift; return ref $h eq 'HASH' ? grep { /^\{/ && index($_, $XMLNS) != 0 } keys %$h : () }
sub _privileges {   # the privileges named in a grant, deny or prop element
  my $x = shift;
  return map { _clark($_) } map { _elements($_) } map { _list($_) } (ref $x eq 'HASH' ? $x->{"${D}privilege"} : undef);
}
sub _href_path { my $h = _text(shift); return undef unless defined $h && length $h; return _unescape_href($h) =~ s{/*\z}{/}r }

# Where user principals live: the principal collection the owner's own
# principal is DIRECTLY below (RFC 3744 S5.8 DAV:principal-collection-set),
# else the owner principal's parent.  No owner: nothing is known (undef).
sub principal_base {
  my ($owner, $collections) = @_;
  return undef unless defined $owner && $owner =~ m{\A(/.*/)[^/]+/\z};
  my $parent = $1;
  my ($base) = grep { $_ eq $parent } @{ $collections || [] };
  return $base // $parent;
}

sub parse_aces {
  my $acl = shift;
  my @aces;
  for my $ace (_list(ref $acl eq 'HASH' ? $acl->{"${D}ace"} : undef)) {
    next unless ref $ace eq 'HASH';
    my %a = (invert => 0, grant => [ _privileges($ace->{"${D}grant"}) ], deny => [ _privileges($ace->{"${D}deny"}) ],
             inherited => exists $ace->{"${D}inherited"} ? 1 : 0, protected => exists $ace->{"${D}protected"} ? 1 : 0);
    my $p = $ace->{"${D}principal"};
    if (!$p && ref $ace->{"${D}invert"} eq 'HASH') { $p = $ace->{"${D}invert"}{"${D}principal"}; $a{invert} = 1 }
    next unless ref $p eq 'HASH';
    if (exists $p->{"${D}href"}) {
      $a{principal} = _href_path($p->{"${D}href"}) // next;
      $a{href} = _text($p->{"${D}href"});   # sent back as it came (a %2F stays %2F)
    }
    elsif (ref $p->{"${D}property"} eq 'HASH') {
      ($a{property}) = _elements($p->{"${D}property"});
      next unless defined $a{property};
      $a{principal} = 'property';
    }
    else { ($a{principal}) = map { _clark($_) } _elements($p); next unless defined $a{principal} }
    push @aces, \%a;
  }
  return \@aces;
}

# DAV:supported-privilege-set (RFC 3744 S5.3) as { name => { parent, abstract } }
sub parse_privilege_tree {
  my ($sps, $parent, $out) = @_;
  $out ||= {};
  for my $sp (_list(ref $sps eq 'HASH' ? $sps->{"${D}supported-privilege"} : undef)) {
    next unless ref $sp eq 'HASH';
    my ($name) = map { _clark($_) } map { _elements($_) } _list($sp->{"${D}privilege"});
    next unless defined $name && !exists $out->{$name};
    $out->{$name} = { parent => $parent, abstract => exists $sp->{"${D}abstract"} ? 1 : 0 };
    parse_privilege_tree($sp, $name, $out);
  }
  return $out;
}

# One resource's access control: { aces, owner, privileges (the tree),
# principalCollections }.  undef when the server would not give the
# DAV:acl property (no ACL support, or no read-acl).
sub AclInfo {
  my ($Self, $path) = @_;
  my $res = $Self->_xml('PROPFIND', $path,
    qq{<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop>}
    . '<D:acl/><D:owner/><D:supported-privilege-set/><D:principal-collection-set/></D:prop></D:propfind>', Depth => 0);
  return undef unless $res->{status} == 207;
  my $tree = eval { _xml_hash($res->{content}) } or return undef;
  (my $want = $path) =~ s{/+\z}{};
  my @resps = _list($tree->{"${D}response"});
  # Cyrus answers a Depth-0 PROPFIND on a collection with its members too
  my ($resp) = (grep { _unescape_href(_text($_->{"${D}href"})) eq $want } @resps);
  $resp //= $resps[0] if @resps == 1;
  return undef unless $resp;
  my %info;
  for my $ps (_list($resp->{"${D}propstat"})) {
    next unless (_text($ps->{"${D}status"}) // '') =~ / 2\d\d /;
    my $prop = $ps->{"${D}prop"};
    next unless ref $prop eq 'HASH';
    $info{aces} = parse_aces($prop->{"${D}acl"}) if exists $prop->{"${D}acl"};
    $info{owner} = _href_path($prop->{"${D}owner"}{"${D}href"}) if ref $prop->{"${D}owner"} eq 'HASH';
    $info{privileges} = parse_privilege_tree($prop->{"${D}supported-privilege-set"})
      if ref $prop->{"${D}supported-privilege-set"} eq 'HASH';
    $info{principalCollections} = [ grep { defined } map { _href_path($_) } _list($prop->{"${D}principal-collection-set"}{"${D}href"}) ]
      if ref $prop->{"${D}principal-collection-set"} eq 'HASH';
  }
  return $info{aces} ? \%info : undef;
}

sub GetAcl { my $i = $_[0]->AclInfo($_[1]); return $i ? $i->{aces} : undef }

# Names come from the server's own ACL or from a client (a FileNode
# shareWith user id), so nothing is interpolated into the XML unchecked: a
# privilege or principal element must be an XML name, a namespace is an
# escaped attribute, and an href is percent-encoded segment by segment
# (a "/" inside a user id cannot add a path segment).  Anything else dies.
my $NCNAME = qr/\A[A-Za-z_][A-Za-z0-9._-]*\z/;
sub _xattr { my $s = _xesc(shift); $s =~ s/"/&quot;/g; return $s }
sub _xml_element {
  my $name = shift // '';
  return "<D:$name/>" if $name =~ $NCNAME;
  return qq{<X:$2 xmlns:X="} . _xattr($1) . '"/>' if $name =~ /\A\{([^{}]+)\}([A-Za-z_][A-Za-z0-9._-]*)\z/;
  die "SetAcl: not an XML name: $name\n";
}
sub _xml_href {
  my $path = shift;
  my @seg = split m{/}, $path, -1;
  return '<D:href>' . _xesc(join('/', map { uri_escape_utf8($_) } @seg)) . '</D:href>';
}
sub acl_xml {
  my $aces = shift;
  my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:acl xmlns:D="DAV:">};
  for my $ace (@$aces) {
    my $p = $ace->{principal} // '';
    # an ACE read from the server goes back with its own href, byte for byte
    my $pr = $p =~ m{^/} ? (defined $ace->{href} && length $ace->{href} ? '<D:href>' . _xesc($ace->{href}) . '</D:href>' : _xml_href($p))
           : $p eq 'property' ? '<D:property>' . _xml_element($ace->{property}) . '</D:property>'
           : _xml_element($p);
    $pr = "<D:principal>$pr</D:principal>";
    $pr = "<D:invert>$pr</D:invert>" if $ace->{invert};
    my ($kind, $privs) = @{ $ace->{deny} || [] } ? ('deny', $ace->{deny}) : ('grant', $ace->{grant} || []);
    die "SetAcl: an ACE without privileges\n" unless @$privs;
    $xml .= "<D:ace>$pr<D:$kind>" . join('', map { '<D:privilege>' . _xml_element($_) . '</D:privilege>' } @$privs)
          . "</D:$kind></D:ace>";
  }
  return "$xml</D:acl>";
}

# RFC 3744 S8.1: replace the resource's non-inherited, non-protected ACEs.
# Returns { status, error }, error being the DAV:error precondition the
# server named (e.g. 'recognized-principal', 'no-abstract'), if any.
sub SetAcl {
  my ($Self, $path, $aces) = @_;
  my $res = $Self->_xml('ACL', $path, acl_xml([ grep { !$_->{inherited} && !$_->{protected} } @$aces ]));
  my ($err) = ($res->{content} // '') =~ m{<(?:[\w.-]+:)?error\b[^>]*>\s*<(?:[\w.-]+:)?([\w.-]+)};
  return { status => $res->{status}, error => $err };
}

sub _try_list { my ($Self, $p) = @_; my $r = eval { $Self->PropFind($p, 1) }; return $r || [] }

# What this server really does, found by trying it (see the spec's "Defending
# against bogus servers"): status codes alone are not trusted.
sub Probe {
  my ($Self, $root) = @_;
  my %f = (syncCollection => 0, acl => 0, deadProps => 0, etagIsContent => 0, quota => 0);
  my $name = "$root/.jmap-probe-" . lc(new_uuid_string() =~ s/-//gr);
  my $bytes = "jmap-probe\n";
  my $put = $Self->Put($name, $bytes, type => 'text/plain', if_none_match => 1);
  return \%f unless $put->{status} =~ /^2/;

  my $ok = eval {
    # dead properties: only if one reads back
    if ($Self->PropPatch($name, { probe => 'x' })) {
      my ($e) = grep { $_->{href} eq $name } @{ $Self->_try_list($root) };
      $f{deadProps} = ($e && ($e->{dead}{probe} // '') eq 'x') ? 1 : 0;
    }
    # content ETags: equal to SHA-1 of the bytes, and unchanged by a MOVE
    if (($put->{etag} // '') eq sha1_hex($bytes)) {
      my $moved = "$name-moved";
      if ($Self->Move($name, $moved) =~ /^2/) {
        my ($e) = grep { $_->{href} eq $moved } @{ $Self->_try_list($root) };
        $f{etagIsContent} = ($e && ($e->{etag} // '') eq $put->{etag}) ? 1 : 0;
        $name = $moved;
      }
    }
    1;
  };
  my $err = $@;
  $Self->Delete($name);   # never leave the scratch file behind
  die $err unless $ok;

  # a MOVE of a collection holding a collection: does an empty collection
  # stay behind at the old name (Cyrus)?  Unknown (undef) if this cannot run
  my $d = "$name-d";
  if (($Self->Mkcol($d) // '') =~ /^2/) {
    if (($Self->Mkcol("$d/b") // '') =~ /^2/ && ($Self->Move("$d/", "$d-moved/") // '') =~ /^2/) {
      $f{moveLeavesEmpty} = $Self->Raw('PROPFIND', "$d/", undef, Depth => 0)->{status} == 207 ? 1 : 0;
      $Self->Delete("$d-moved/b/");
      $Self->Delete("$d-moved/");
    }
    $Self->Delete("$d/b/");
    $Self->Delete("$d/");
  }

  $f{syncCollection} = $Self->SyncCollection($root, '') ? 1 : 0;
  # RFC 3744 S7.2: an ACL server says "access-control" in its DAV header;
  # and the DAV:acl property must really be readable
  my $opt = eval { $Self->Raw('OPTIONS', "$root/") } || {};
  my $davhdr = join(',', _list(($opt->{headers} || {})->{dav}));
  my $acl = $davhdr =~ /(?:^|,)\s*access-control\s*(?:,|\z)/ ? eval { $Self->AclInfo("$root/") } : undef;
  if ($acl) {
    $f{acl} = 1;
    $f{privileges} = $acl->{privileges} if $acl->{privileges} && %{ $acl->{privileges} };
    # where user principals live (Cyrus: /dav/principals/user/)
    my $base = principal_base($acl->{owner}, $acl->{principalCollections});
    $f{principalBase} = $base if defined $base;
  }
  my $q = $Self->_xml('PROPFIND', "$root/",
    qq{<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:quota-used-bytes/></D:prop></D:propfind>}, Depth => 0);
  $f{quota} = ($q->{status} == 207 && ($q->{content} // '') =~ m{quota-used-bytes>\d}) ? 1 : 0;
  return \%f;
}

1;
