package JMAP::FileNode;

# Pure logic for FileNode over WebDAV (draft-ietf-jmap-filenode): ids, blob
# ids, name rules, globs, rights, reconciliation, set ordering, filters and
# sorts.  No I/O, no DB -- like JMAP::Dispatch and JMAP::Collation.

use strict;
use warnings;
use JSON;
use B ();
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
  return qr/\A$re\z/si;
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
# directory -- [id, ".~tmp~id"], or a free variant of it if that is taken
# -- and moving it on, [id, undef], once the others are done (as hm's
# _get_ordered_update_keys).
#
# Optional: $parent ({ id => current parent id }) keeps a directory from
# being moved into its own current subtree: such a move waits until the
# node between them has moved away (the final tree is checked for cycles
# by the caller).  $after ({ id => [ids] }) makes a move wait until those
# ids have left (a destroy that must follow them).  $park_in ({ id =>
# dirid }) parks a node in that directory instead of its current one: a
# node inside a directory that this call destroys must be parked outside
# it, and once parked there it counts as having left (for $after).
# Returns [ [id, $temp_or_undef, $parkdir_or_undef], ... ].
sub order_moves {
  my ($moves, $occupant, $parent, $after, $park_in) = @_;
  my %pending = %$moves;
  my %held = %$occupant;
  my %par = %{ $parent || {} };
  my %after = %{ $after || {} };
  my (@steps, @parked, %unfinished);
  %unfinished = map { $_ => 1 } keys %pending;
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
  my $waits = sub { my $id = shift; return grep { $_ ne $id && $unfinished{$_} } @{ $after{$id} || [] } };
  while (%pending) {
    my $progress = 0;
    for my $id (sort keys %pending) {
      next if $name_blocked->($id) || $waits->($id);
      my ($np) = split /\0/, $pending{$id}, 2;
      next if length $np && $inside->($np, $id);
      push @steps, [$id, undef];
      $place->($id, $pending{$id});
      $par{$id} = $np if length $np;
      delete $pending{$id};
      delete $unfinished{$id};
      $progress = 1;
    }
    next if $progress;
    my $park = sub {
      my $id = shift;
      # the parking spot is in the node's current directory (or the one
      # the caller names, unless that lies inside the node), and free
      my ($cur) = grep { $held{$_} eq $id } keys %held;
      my $dir = defined $cur ? (split /\0/, $cur, 2)[0] : '';
      my $elsewhere = $park_in && defined $park_in->{$id} && !$inside->($park_in->{$id}, $id);
      $dir = $park_in->{$id} if $elsewhere;
      my %taken = map { (lc((split /\0/, $_, 2)[1]) => 1) } grep { /^\Q$dir\E\0/ } keys %held;
      my $temp = ".~tmp~$id";
      $temp = unique_name($temp, \%taken, 1) if $taken{ lc $temp };
      push @steps, [$id, $temp, ($elsewhere ? $dir : undef)];
      $place->($id, "$dir\0$temp");
      if ($elsewhere) { $par{$id} = $dir; delete $unfinished{$id} }
      push @parked, [$id, $pending{$id}];
      delete $pending{$id};
    };
    # stuck: park the first node that waits on a name ...
    my ($id) = grep { $name_blocked->($_) } sort keys %pending;
    if (defined $id) { $park->($id); next }
    # ... or, if moves wait on each other through $after (two replaces each
    # displacing the other's directory), park the ones waited on outside
    # their doomed directories: parked there they have left ...
    my %waited = map { ($_ => 1) } map { $waits->($_) } keys %pending;
    my @out = grep { $pending{$_} && $park_in && defined $park_in->{$_} && !$inside->($park_in->{$_}, $_) }
              sort keys %waited;
    if (@out) { $park->($_) for @out; next }
    # ... or, with only tree or $after waits left, let the server judge them
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

use JMAP::Collation;

sub _ancestors {
  my ($id, $byid) = @_;
  my @a;
  my %seen;
  for (my $p = $byid->{$id} ? $byid->{$id}{parentId} : undef; defined $p && !$seen{$p}++; $p = $byid->{$p} ? $byid->{$p}{parentId} : undef) {
    push @a, $p;
  }
  return @a;
}

# draft S3.2.5 FilterCondition / RFC 8620 FilterOperator.
# Like epoch, but keeps fractional seconds, so "...00.5Z" sorts after "...00Z".
sub epoch_frac {
  my $s = shift // '';
  my $t = epoch($s);
  return undef unless defined $t;
  my ($f) = $s =~ /(\.\d+)Z\z/;
  return $t + ($f // 0);
}

# Why a filter's condition values are the wrong type, or undef (draft S3.2.5
# types: Boolean, Id/String, UnsignedInt, UTCDate).  Walks FilterOperators.
sub filter_problem {
  my ($f) = @_;
  return 'a filter must be an object' unless ref $f eq 'HASH';
  if (exists $f->{operator}) {
    for my $c (@{ $f->{conditions} || [] }) {
      my $why = filter_problem($c);
      return $why if $why;
    }
    return undef;
  }
  my $isbool = sub { ref $_[0] && JSON::is_bool($_[0]) };
  my $isuint = sub {
    return 0 if !defined $_[0] || ref $_[0];
    my $fl = B::svref_2object(\$_[0])->FLAGS;
    return 0 unless $fl & (B::SVf_IOK | B::SVf_NOK);
    return $_[0] >= 0 && $_[0] == int($_[0]);
  };
  my $isstr = sub {
    return 0 if !defined $_[0] || ref $_[0];
    return (B::svref_2object(\$_[0])->FLAGS & B::SVf_POK) ? 1 : 0;
  };
  for my $k (sort keys %$f) {
    my $v = $f->{$k};
    if ($k =~ /\A(?:isTopLevel|hasAnyRole|isExecutable)\z/) {
      return "$k must be a boolean" unless $isbool->($v);
    }
    elsif ($k =~ /\A(?:minSize|maxSize)\z/) {
      return "$k must be an unsigned integer" unless $isuint->($v);
    }
    elsif ($k =~ /(?:Before|After)\z/) {
      return "$k must be a UTCDate" unless $isstr->($v) && defined epoch($v);
    }
    else {
      return "$k must be a string" unless $isstr->($v);
    }
  }
  return undef;
}

# draft S3.2.5 FilterCondition / RFC 8620 FilterOperator.
#
# $ctx->{depth} (draft "depth": levels of subdirectories to recurse into)
# widens parentId and isTopLevel, and only those: ancestorId is already
# recursive.  It applies to the top-level condition and through a top-level
# AND; below OR or NOT the conditions keep their exact meaning.
sub filter_match {
  my ($o, $f, $ctx) = @_;
  my $depth = $ctx->{depth} || 0;
  if (exists $f->{operator}) {
    my @c = @{ $f->{conditions} || [] };
    if ($f->{operator} eq 'AND') {
      return (grep { !filter_match($o, $_, $ctx) } @c) ? 0 : 1;
    }
    my $sub = { %$ctx, depth => 0 };
    return (grep {  filter_match($o, $_, $sub) } @c) ? 1 : 0 if $f->{operator} eq 'OR';
    return (grep {  filter_match($o, $_, $sub) } @c) ? 0 : 1;   # NOT
  }
  my $byid = $ctx->{byid};
  my $date = sub { epoch_frac($_[0]) // 0 };
  if (exists $f->{isTopLevel}) {
    my $top = !defined $o->{parentId};
    $top = 1 if !$top && $f->{isTopLevel} && $depth && scalar(my @a = _ancestors($o->{id}, $byid)) <= $depth;
    return 0 unless !!$top == !!$f->{isTopLevel};
  }
  if (defined $f->{parentId}) {
    my $ok = ($o->{parentId} // '') eq $f->{parentId};
    if (!$ok && $depth) {
      my @a = _ancestors($o->{id}, $byid);
      my ($i) = grep { $a[$_] eq $f->{parentId} } 0 .. $#a;
      $ok = defined $i && $i <= $depth;
    }
    return 0 unless $ok;
  }
  if (defined $f->{ancestorId})  { return 0 unless grep { $_ eq $f->{ancestorId} } _ancestors($o->{id}, $byid) }
  if (defined $f->{descendantId}){ return 0 unless grep { $_ eq $o->{id} } _ancestors($f->{descendantId}, $byid) }
  if (defined $f->{nodeType})    { return 0 unless $o->{nodeType} eq $f->{nodeType} }
  if (defined $f->{role})        { return 0 unless ($o->{role} // '') eq $f->{role} }
  if (exists $f->{hasAnyRole})   { return 0 unless !!defined($o->{role}) == !!$f->{hasAnyRole} }
  if (defined $f->{blobId})      { return 0 unless ($o->{blobId} // '') eq $f->{blobId} }
  if (exists $f->{isExecutable}) { return 0 unless !!$o->{executable} == !!$f->{isExecutable} }
  for my $p (qw(created modified accessed)) {
    if (defined $f->{"${p}Before"}) { return 0 unless $date->($o->{$p}) <  $date->($f->{"${p}Before"}) }
    if (defined $f->{"${p}After"})  { return 0 unless $date->($o->{$p}) >= $date->($f->{"${p}After"}) }
  }
  if (defined $f->{minSize})     { return 0 unless defined $o->{size} && $o->{size} >= $f->{minSize} }
  if (defined $f->{maxSize})     { return 0 unless defined $o->{size} && $o->{size} <  $f->{maxSize} }
  if (defined $f->{name})        { return 0 unless $o->{name} eq $f->{name} }
  if (defined $f->{nameMatch})   { return 0 unless $o->{name} =~ glob_regex($f->{nameMatch}) }
  if (defined $f->{type})        { return 0 unless ($o->{type} // '') eq $f->{type} }
  if (defined $f->{typeMatch})   { return 0 unless ($o->{type} // '') =~ glob_regex($f->{typeMatch}) }
  if (defined $f->{text}) {
    my $g = glob_regex("*$f->{text}*");
    return 0 unless $o->{name} =~ $g || ($o->{type} // '') =~ $g;
  }
  return 1;
}

my %NODE_ORDER = (directory => 0, symlink => 1, file => 2);

sub sort_nodes {
  my ($objs, $sort, $byid) = @_;
  my %keys;
  my $desc = sub { defined $_[0]{isAscending} && !$_[0]{isAscending} };
  my $cmp_one = sub {
    my ($c, $x, $y) = @_;
    my $p = $c->{property};
    my $r;
    if ($p eq 'name') {
      $r = JMAP::Collation::compare($c->{collation}, $x->{name}, $y->{name}, \%keys);
      $r = -$r if $desc->($c);
    }
    elsif ($p eq 'nodeType') {
      $r = $NODE_ORDER{$x->{nodeType}} <=> $NODE_ORDER{$y->{nodeType}};
      $r = -$r if $desc->($c);
    }
    elsif ($p eq 'type') {
      # directories (non-files) stay first either way; only the media type reverses
      $r = $NODE_ORDER{$x->{nodeType}} <=> $NODE_ORDER{$y->{nodeType}};
      unless ($r) {
        $r = JMAP::Collation::compare($c->{collation}, $x->{type} // '', $y->{type} // '', \%keys);
        $r = -$r if $desc->($c);
      }
    }
    elsif ($p eq 'size') {
      # null sizes (directories) last in both directions
      $r = (defined $x->{size} ? 0 : 1) <=> (defined $y->{size} ? 0 : 1);
      unless ($r) {
        $r = ($x->{size} // 0) <=> ($y->{size} // 0);
        $r = -$r if $desc->($c);
      }
    }
    else {
      $r = (epoch_frac($x->{$p}) // 0) <=> (epoch_frac($y->{$p}) // 0);
      $r = -$r if $desc->($c);
    }
    return $r;
  };
  my @flat = grep { ($_->{property} // '') ne 'tree' } @$sort;
  my $cmp = sub { my ($x, $y) = @_; for my $c (@flat) { my $r = $cmp_one->($c, $x, $y); return $r if $r } return $x->{id} cmp $y->{id} };
  my ($tree) = grep { ($_->{property} // '') eq 'tree' } @$sort;
  return [ sort { $cmp->($a, $b) } @$objs ] unless $tree;

  # draft S3.2.5 "tree": by name, each directory immediately followed by its
  # sorted children.  Walk the whole tree (a filtered-out parent still places
  # its matched descendants) and emit only the matched nodes; then any matched
  # node the walk never reached (a parentId cycle from a bogus server) goes on
  # the end by name, so no id is ever dropped.
  my $tc = { property => 'name', collation => $tree->{collation}, isAscending => $tree->{isAscending} };
  my $order = sub { $cmp_one->($tc, $_[0], $_[1]) || $_[0]{id} cmp $_[1]{id} };
  my %want = map { $_->{id} => 1 } @$objs;
  my %kids;
  for my $n (values %$byid) {
    push @{ $kids{ defined $n->{parentId} && $byid->{$n->{parentId}} ? $n->{parentId} : '' } }, $n;
  }
  my (@out, %seen);
  my $walk;
  $walk = sub {
    for my $n (sort { $order->($a, $b) } @{ $kids{$_[0]} || [] }) {
      next if $seen{$n->{id}}++;
      push @out, $n if $want{$n->{id}};
      $walk->($n->{id});
    }
  };
  $walk->('');
  push @out, sort { $order->($a, $b) } grep { !$seen{$_->{id}} } @$objs;
  return \@out;
}

1;
