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
# R7: an empty or absent current-user-privilege-set means "not reported" (Cyrus
# lists files with none).  Such a node inherits its parent collection's
# privileges, walking up until a non-empty set is found; only a non-empty set
# is authoritative.  Returns an arrayref, or undef when nothing up the chain
# reports one (rights() then grants everything).  $parent_of is a code ref
# mapping a row to its parent row (or undef).
sub effective_privs {
  my ($row, $parent_of) = @_;
  my %seen;
  while ($row && !$seen{$row->{nodeid}}++) {
    return [ split ' ', $row->{privs} ] if defined $row->{privs} && length $row->{privs};
    $row = $parent_of->($row);
  }
  return undef;
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

# The mirror's deadprops column: an entry's J: dead properties as canonical
# JSON (so equal sets compare equal), or undef when there are none.
my $CANON = JSON->new->canonical->utf8;   # bytes, as DBD::SQLite hands them back
# Values are strings, as a multistatus reads them back, so a mirror value
# set by the proxy (executable => 1) equals the server's ("1").
sub dead_json {
  my $d = shift;
  return undef unless $d && %$d;
  return $CANON->encode({ map { ($_ => defined $d->{$_} ? "$d->{$_}" : undef) } keys %$d });
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
    # client-set values kept as dead properties change the object too
    return 1 if ($row->{deadprops} // '') ne (dead_json($e->{dead}) // '');
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


# draft S3.2.3: creations whose parentId is "#cid" must follow cid.  Any
# left in a cycle of #refs go last, where their parentId does not resolve
# and they fail with invalidProperties.
sub order_creates {
  my $create = shift;
  my (@order, %done);
  my @todo = sort keys %$create;
  my $progress = 1;
  while (@todo && $progress) {
    $progress = 0;
    my @next;
    for my $cid (@todo) {
      my $p = ref $create->{$cid} eq 'HASH' ? ($create->{$cid}{parentId} // '') : '';   # non-objects fail later
      if ($p =~ /^#(.+)\z/s && exists $create->{$1} && !$done{$1}) { push @next, $cid; next }
      push @order, $cid;
      $done{$cid} = $progress = 1;
    }
    @todo = @next;
  }
  return [ @order, @todo ];
}

# draft S3.2.3: sibling names must stay unique at every step of a /set.
# $moves is { id => "newparent\0newname" }, $occupant { "parent\0name" => id }
# for the current tree (names folded by the caller when matching is
# case-insensitive).  A move whose destination is held by another mover
# waits for it to leave; a cycle of such waits (a swap, a rotation) is
# broken by first parking one node under a temporary name in its current
# directory -- [id, ".~tmp~id"] -- and moving it on, [id, undef], once the
# others are done (as hm's _get_ordered_update_keys).  With $parent
# ({ id => current parent id }), a directory is never moved into its own
# current subtree: such a move waits until the node between them has moved
# away (the final tree is checked for cycles by the caller).  Returns
# [ [id, $temp_or_undef], ... ].
sub order_moves {
  my ($moves, $occupant, $parent) = @_;
  my %pending = %$moves;
  my %held = %$occupant;
  my %par = %{ $parent || {} };
  my (@steps, @parked);
  my $place = sub {
    my ($id, $dest) = @_;
    delete $held{$_} for grep { $held{$_} eq $id } keys %held;
    $held{$dest} = $id if defined $dest;
  };
  my $inside = sub {   # is $dir $id itself or one of its current descendants?
    my ($dir, $id) = @_;
    my %seen;
    for (my $a = $dir; defined $a && !$seen{$a}++; $a = $par{$a}) { return 1 if $a eq $id }
    return 0;
  };
  my $name_blocked = sub {
    my $id = shift;
    my $holder = $held{ $pending{$id} };
    return defined $holder && $holder ne $id && exists $pending{$holder};
  };
  while (%pending) {
    my $progress = 0;
    for my $id (sort keys %pending) {
      next if $name_blocked->($id);
      my ($np) = split /\0/, $pending{$id}, 2;
      next if length $np && $inside->($np, $id);
      push @steps, [$id, undef];
      $place->($id, $pending{$id});
      $par{$id} = $np if length $np;
      delete $pending{$id};
      $progress = 1;
    }
    next if $progress;
    # stuck: park the first node that waits on a name ...
    my ($id) = grep { $name_blocked->($_) } sort keys %pending;
    if (defined $id) {
      push @steps, [$id, ".~tmp~$id"];
      $place->($id, undef);
      push @parked, [$id, $pending{$id}];
      delete $pending{$id};
      next;
    }
    # ... or, with only tree waits left (the final tree has a cycle, which
    # the caller should have refused), let the server judge them
    push @steps, map { [$_, undef] } sort keys %pending;
    %pending = ();
  }
  push @steps, map { [$_->[0], undef] } @parked;
  return \@steps;
}

# draft S3.2.3 onExists "rename": name[2].ext, name[3].ext, ... -- the
# extension is the part after the last "." unless that "." starts the name.
# $taken holds the sibling names, lower-cased when $ci is true.
sub unique_name {
  my ($name, $taken, $ci) = @_;
  my ($base, $ext) = $name =~ /^(.+)(\.[^.]+)\z/s ? ($1, $2) : ($name, '');
  for my $n (2 .. 100_000) {
    my $try = "$base\[$n\]$ext";
    my $k = $try;
    if ($ci) { utf8::upgrade($k); $k = lc $k }   # Unicode lc, whatever the representation
    return $try unless $taken->{$k};
  }
  die "no free name for $name\n";
}

1;
