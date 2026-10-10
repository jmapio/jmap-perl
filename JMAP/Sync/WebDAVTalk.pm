package JMAP::Sync::WebDAVTalk;

# WebDAV (RFC 4918) for FileNode: requests and multistatus normalisation.
# Protocol only -- no DB.  Paths are absolute and URI-unescaped; request_url
# (Net::DAVTalk) escapes each segment exactly once.

use strict;
use warnings;
use parent 'Net::DAVTalk';
use Net::DAVTalk::XMLParser;
use Encode qw(decode_utf8 encode_utf8);
use URI::Escape qw(uri_unescape);
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

# RFC 4918 S14.16: a multistatus of responses.  Returns normalised entries.
sub parse_multistatus {
  my ($xml) = @_;
  return [] unless defined $xml && $xml =~ /<[^?!]/;
  my $tree = eval { xmlToHash($xml) };
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
    <J:executable/><J:accessed/><J:created/><J:modified/><J:isSubscribed/><J:role/>
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

sub PropFind {
  my ($Self, $path, $depth) = @_;
  my $res = $Self->_xml('PROPFIND', $path, $PROPFIND_BODY, Depth => $depth // 1);
  die "PROPFIND $path: HTTP $res->{status}\n" unless $res->{status} == 207;
  return parse_multistatus($res->{content});
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

sub GetAcl {
  my ($Self, $path) = @_;
  my $res = $Self->_xml('PROPFIND', $path,
    qq{<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:acl/></D:prop></D:propfind>}, Depth => 0);
  return undef unless $res->{status} == 207;
  my $tree = eval { xmlToHash($res->{content}) } or return undef;
  my @aces;
  for my $resp (_list($tree->{"${D}response"})) {
    for my $ps (_list($resp->{"${D}propstat"})) {
      next unless (_text($ps->{"${D}status"}) // '') =~ / 200 /;
      my $acl = $ps->{"${D}prop"}{"${D}acl"} or next;
      for my $ace (_list($acl->{"${D}ace"})) {
        my $p = $ace->{"${D}principal"} || {};
        my $principal = $p->{"${D}href"} ? _unescape_href(_text($p->{"${D}href"})) . '/'
                      : (map { s/^\{DAV:\}//r } grep { /^\{DAV:\}/ } keys %$p)[0];
        my @grant = map { my $x = $_; map { s/^\{DAV:\}//r } grep { /^\{DAV:\}/ } keys %$x }
                    map { _list($_) } (($ace->{"${D}grant"} || {})->{"${D}privilege"});
        push @aces, { principal => $principal, grant => \@grant,
                      inherited => exists $ace->{"${D}inherited"} ? 1 : 0 };
      }
    }
  }
  return \@aces;
}

sub SetAcl {
  my ($Self, $path, $aces) = @_;
  my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:acl xmlns:D="DAV:">};
  for my $ace (@$aces) {
    my $pr = $ace->{principal} =~ m{^/} ? '<D:href>' . _xesc($ace->{principal}) . '</D:href>' : "<D:$ace->{principal}/>";
    $xml .= "<D:ace><D:principal>$pr</D:principal><D:grant>"
          . join('', map { "<D:privilege><D:$_/></D:privilege>" } @{$ace->{grant}})
          . '</D:grant></D:ace>';
  }
  $xml .= '</D:acl>';
  return $Self->_xml('ACL', $path, $xml)->{status};
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

  $f{syncCollection} = $Self->SyncCollection($root, '') ? 1 : 0;
  $f{acl} = defined $Self->GetAcl("$root/") ? 1 : 0;
  my $q = $Self->_xml('PROPFIND', "$root/",
    qq{<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:quota-used-bytes/></D:prop></D:propfind>}, Depth => 0);
  $f{quota} = ($q->{status} == 207 && ($q->{content} // '') =~ m{quota-used-bytes>\d}) ? 1 : 0;
  return \%f;
}

1;
