package JMAP::FileNode;

# Pure logic for FileNode over WebDAV (draft-ietf-jmap-filenode): ids, blob
# ids, name rules, globs, rights, reconciliation, set ordering, filters and
# sorts.  No I/O, no DB -- like JMAP::Dispatch and JMAP::Collation.

use strict;
use warnings;
use JSON;
use Encode qw(encode_utf8);
use Digest::SHA qw(sha1_hex);
use Data::UUID::LibUUID qw(new_uuid_string);
use POSIX qw(strftime);
use Time::Local qw(timegm);

our %CAPS = (
  maxFileNodeDepth          => undef,
  maxSizeFileNodeName       => 255,
  forbiddenNameChars        => '/',
  forbiddenNodeNames        => ['.', '..'],
  caseInsensitiveNames      => JSON::false,
  mayCreateTopLevelFileNode => JSON::false,
  fileNodeQuerySortOptions  => [qw(name type size created modified accessed nodeType tree)],
  webTrashUrl               => undef,
  webUrlTemplate            => undef,
);

sub local_id  { return 'L' . lc(new_uuid_string() =~ s/-//gr) }
sub server_id { return 'S' . substr(sha1_hex(encode_utf8($_[0])), 0, 32) }

sub blob_id { my ($nodeid, $etag) = @_; return "d-$nodeid-" . substr(sha1_hex(encode_utf8($etag // '')), 0, 16) }
sub parse_blob_id { return ($_[0] // '') =~ /^d-([LS][0-9a-f]{32}|[LS]\w+)-([0-9a-f]{16})$/ ? ($1, $2) : () }

# draft S3.1 "name" and the capability: non-empty, <= 255 UTF-8 octets, no
# forbidden characters or names, no control characters.
sub name_problem {
  my $name = shift;
  return 'name must be a non-empty string' unless defined $name && !ref $name && length $name;
  return 'name is longer than maxSizeFileNodeName' if length(encode_utf8($name)) > $CAPS{maxSizeFileNodeName};
  my $chars = quotemeta $CAPS{forbiddenNameChars};
  return 'name contains a forbidden character' if $name =~ /[$chars]/;
  return 'name contains a control character' if $name =~ /[\x00-\x1f\x7f]/;
  return 'name is forbidden' if grep { lc $_ eq lc $name } @{ $CAPS{forbiddenNodeNames} };
  return undef;
}

# draft S3.2.5 nameMatch: * ? [set] [!set] [^set], anchored, case-insensitive.
sub glob_regex {
  my $glob = shift // '';
  my $re = '';
  while (length $glob) {
    if    ($glob =~ s/^\*//)                { $re .= '.*' }
    elsif ($glob =~ s/^\?//)                { $re .= '.' }
    elsif ($glob =~ s/^\[([!^]?)([^\]]+)\]//) {
      my ($neg, $set) = ($1, $2);
      $set =~ s/([\\\]\[^])/\\$1/g;
      $re .= '[' . ($neg ? '^' : '') . $set . ']';
    }
    else { $glob =~ s/^(.)//s; $re .= quotemeta $1 }
  }
  return qr/^$re$/si;
}

# RFC 3744 privileges -> draft S3.1 FilesRights.  DAV:all and DAV:write are
# aggregates.  Deleting or moving a node is an unbind on its parent.
sub _expand {
  my $privs = shift;
  my %p = map { $_ => 1 } @$privs;
  @p{qw(read write write-content write-properties bind unbind write-acl read-acl)} = (1) x 8 if $p{all};
  @p{qw(write-content write-properties bind unbind)} = (1) x 4 if $p{write};
  return \%p;
}
sub rights {
  my ($privs, $parent) = @_;
  return { map { $_ => JSON::true } qw(mayRead mayAddChildren mayRename mayDelete mayModifyContent mayShare) }
    unless defined $privs;
  my $p  = _expand($privs);
  my $pp = defined $parent ? _expand($parent) : { unbind => 1 };
  my $b = sub { $_[0] ? JSON::true : JSON::false };
  return {
    mayRead          => $b->($p->{read}),
    mayAddChildren   => $b->($p->{bind}),
    mayRename        => $b->($pp->{unbind}),
    mayDelete        => $b->($pp->{unbind}),
    mayModifyContent => $b->($p->{'write-content'}),
    mayShare         => $b->($p->{'write-acl'}),
  };
}

sub utc { my $t = shift; return defined $t ? strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($t)) : undef }
sub epoch {
  my $s = shift // '';
  return undef unless $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z$/;
  return eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
}

1;
