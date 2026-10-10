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
sub parse_blob_id { return ($_[0] // '') =~ /^d-([LS][0-9a-f]{32}|[LS]\w+)-([0-9a-f]{16})\z/ ? ($1, $2) : () }

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
# nameMatch comes straight from clients, so this never dies: a bracket set
# that cannot be compiled (e.g. a reversed range like [z-a]) and an
# unterminated '[' are both treated as literal text.
sub glob_regex {
  my $glob = shift // '';
  my $re = '';
  while (length $glob) {
    if    ($glob =~ s/^\*//) { $re .= '.*' }
    elsif ($glob =~ s/^\?//) { $re .= '.' }
    elsif ($glob =~ /^\[([!^]?)([^\]]+)\]/) {
      my ($neg, $set) = ($1, $2);
      (my $escaped = $set) =~ s/([\\\]\[^])/\\$1/g;
      my $cls = ($neg ? '^' : '') . $escaped;
      if (eval { qr/[$cls]/; 1 }) {
        $re .= "[$cls]";
        substr($glob, 0, length($neg) + length($set) + 2, '');
      }
      else {
        $re .= '\\['; substr($glob, 0, 1, '');
      }
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

# Always returns exactly one value (int or undef), never an empty list, so it
# is safe inside hash constructors.
sub epoch {
  my $s = shift // '';
  return undef unless $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z\z/;
  my $t = eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
  return $t;
}

# Match a complete fresh listing against the mirror (spec "Ids" and
# "Defending against bogus servers").  A fingerprint match is only accepted
# when it is unique on both sides.  Entries in "create" are the caller's own
# listing hashrefs, with {nodeid} assigned onto them.
sub reconcile {
  my ($mirror, $listing, $features) = @_;
  $features ||= {};
  # A bogus server may list one href twice; keep the first so it is one node.
  my %seen_href;
  $listing = [ grep { !$seen_href{$_->{href}}++ } @$listing ];
  my (%row_used, %entry_used, @update);
  my $type_of = sub { $_[0]{isCollection} ? 'directory' : 'file' };
  # privileges count: a changed ACL changes the derived myRights (draft "Access Control")
  my $changed = sub {
    my ($row, $e) = @_;
    my $eprivs = defined $e->{privileges} ? join(' ', @{$e->{privileges}}) : undef;
    return 1 if ($row->{privs} // '') ne ($eprivs // '');
    return scalar grep { ($row->{$_} // '') ne ($e->{$_} // '') } qw(href etag size modified type);
  };
  my $pair = sub {
    my ($row, $e) = @_;
    $row_used{$row->{nodeid}} = $entry_used{$e->{href}} = 1;
    push @update, [$row, $e] if $changed->($row, $e);
  };

  # 1. server stable ids (a fileid seen twice on either side is ambiguous)
  my (%rows_by_fileid, %entries_by_fileid);
  push @{ $rows_by_fileid{$_->{fileid}} }, $_ for grep { defined $_->{fileid} } @$mirror;
  push @{ $entries_by_fileid{$_->{fileid}} }, $_ for grep { defined $_->{fileid} } @$listing;
  for my $id (sort keys %entries_by_fileid) {
    next unless @{ $rows_by_fileid{$id} || [] } == 1 && @{ $entries_by_fileid{$id} } == 1;
    my ($row, $e) = ($rows_by_fileid{$id}[0], $entries_by_fileid{$id}[0]);
    next if $row->{nodetype} ne $type_of->($e);   # a change of kind is not the same node
    $pair->($row, $e);
  }
  # 2. same path, same kind
  my %rows_by_href;
  push @{ $rows_by_href{$_->{href}} }, $_ for grep { !$row_used{$_->{nodeid}} } @$mirror;
  for my $e (grep { !$entry_used{$_->{href}} } @$listing) {
    my $rows = $rows_by_href{$e->{href}} or next;
    next unless @$rows == 1;
    my $row = $rows->[0];
    next if $row_used{$row->{nodeid}} || $row->{nodetype} ne $type_of->($e);
    $pair->($row, $e);
  }
  # 3. files only: fingerprints, strongest first, unique on both sides
  my $sizemod = sub { defined $_[0]{size} && defined $_[0]{modified} ? "$_[0]{size}/$_[0]{modified}" : undef };
  my @tiers = (
    [ sub { $_[0]{fingerprint} }, sub { $_[0]{sha1} } ],
    ($features->{etagIsContent} ? [ sub { $_[0]{etag} }, sub { $_[0]{etag} } ] : ()),
    [ $sizemod, $sizemod ],
  );
  for my $tier (@tiers) {
    my ($rk, $ek) = @$tier;
    my (%rows, %entries);
    for my $row (grep { !$row_used{$_->{nodeid}} && $_->{nodetype} eq 'file' } @$mirror) {
      my $k = $rk->($row);
      push @{ $rows{$k} }, $row if defined $k;
    }
    for my $e (grep { !$entry_used{$_->{href}} && !$_->{isCollection} } @$listing) {
      my $k = $ek->($e);
      push @{ $entries{$k} }, $e if defined $k;
    }
    for my $k (sort keys %rows) {
      next unless @{$rows{$k}} == 1 && @{ $entries{$k} || [] } == 1;
      $pair->($rows{$k}[0], $entries{$k}[0]);
    }
  }

  # a fileid repeated in the listing cannot name two nodes: fall back to local ids
  # an S id is never reused for a different node in one pass: if any mirror row
  # (matched or not) already holds it, the new node gets a local id
  my %mirror_ids = map { $_->{nodeid} => 1 } @$mirror;
  my @create;
  for my $e (grep { !$entry_used{$_->{href}} } @$listing) {
    my $sid = defined $e->{fileid} && @{ $entries_by_fileid{$e->{fileid}} } == 1
            ? server_id($e->{fileid}) : undef;
    $e->{nodeid} = defined $sid && !$mirror_ids{$sid} ? $sid : local_id();
    push @create, $e;
  }
  my @destroy = grep { !$row_used{$_->{nodeid}} } @$mirror;
  return { create => \@create, update => \@update, destroy => \@destroy };
}

1;
