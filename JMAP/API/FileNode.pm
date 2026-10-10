package JMAP::API;
use strict;
use warnings;

# FileNode (draft-ietf-jmap-filenode) over the jfilenodes mirror that
# JMAP::ImapDB::sync_files keeps of the account's WebDAV tree.

use JSON;
use JMAP::FileNode;

my @FILENODE_PROPERTIES = qw(
  id parentId nodeType blobId target size name type created modified
  accessed changed executable isSubscribed myRights shareWith role
);

# draft S3.1: one mirror row as a FileNode object.  $byid maps nodeid to row,
# for the parent's privileges (mayRename and mayDelete are rights over the
# parent: WebDAV's unbind).
sub _filenode_object {
  my ($Self, $row, $byid) = @_;
  my $up = sub { defined $_[0]{parentid} ? $byid->{$_[0]{parentid}} : undef };
  my $isfile = $row->{nodetype} eq 'file';
  # client-set values the server keeps as dead properties override the
  # server's own (ImapDB::_filenode_cols keeps them apart); a pin holds
  # only while the server's value is the one the MOVE left (JMAP::FileNode
  # "Pins"), and is never a property of its own
  my $dead = JMAP::FileNode::dead_effective(JMAP::FileNode::dead_decode($row->{deadprops}), $row);
  my $dtime = sub { JMAP::FileNode::epoch($dead->{$_[0]}) };
  my $dbool = sub { defined $dead->{$_[0]} ? ($dead->{$_[0]} =~ /\A\s*(?:1|true)\s*\z/i ? 1 : 0) : undef };
  my $created  = $dtime->('created')  // $row->{created}  // $row->{modified} // $row->{changed};
  my $modified = $dtime->('modified') // $row->{modified} // $row->{changed};
  my $accessed = $dtime->('accessed') // $row->{accessed} // $modified;
  my $executable   = $dbool->('executable')   // $row->{executable};
  my $isSubscribed = $dbool->('isSubscribed') // $row->{isSubscribed} // 1;
  # the features as _filenode_init loaded them (no I/O here: this runs
  # inside transactions too)
  my $features = $Self->{db}->can('filenode_features_cached') ? $Self->{db}->filenode_features_cached() : {};
  my $rights = JMAP::FileNode::node_rights($row, $up, $features);
  # the home collection is the account's single top-level node: it cannot
  # be renamed, moved or destroyed (mayCreateTopLevelFileNode is false)
  @$rights{qw(mayRename mayDelete)} = (JSON::false, JSON::false) unless defined $row->{parentid};
  return {
    id           => "$row->{nodeid}",
    parentId     => (defined $row->{parentid} ? "$row->{parentid}" : undef),
    nodeType     => $row->{nodetype},
    blobId       => $isfile ? JMAP::FileNode::blob_id($row->{nodeid}, $row->{etag}) : undef,
    target       => undef,
    size         => $isfile ? 0 + ($row->{size} // 0) : undef,
    name         => $row->{name},
    type         => $isfile ? ($dead->{type} // $row->{type}) : undef,
    created      => JMAP::FileNode::utc($created),
    modified     => JMAP::FileNode::utc($modified),
    accessed     => JMAP::FileNode::utc($accessed),
    changed      => JMAP::FileNode::utc($row->{changed}),
    executable   => $executable ? JSON::true : JSON::false,
    isSubscribed => $isSubscribed ? JSON::true : JSON::false,
    myRights     => $rights,
    # draft S3.1: null unless the user may share it (and when nobody is
    # shared with); from the mirror, which every listing keeps up to date
    shareWith    => $rights->{mayShare} ? $Self->{db}->filenode_sharewith($row) : undef,
    role         => $row->{role},
  };
}

# Sync first when the mirror is stale (spec "Sync": 60s on demand), even
# the account's first sync if the backfill worker has not done it yet: a
# user is waiting on this request.  The sync talks to WebDAV, so it MUST
# run before _api_init opens the transaction.
sub _filenode_init {
  my ($Self, $args, $maxage) = @_;
  my $mine = !($args->{accountId} && $args->{accountId} ne $Self->{db}->accountid());
  $Self->{db}->sync_files_if_due($maxage // 60, { first => 1 })
    if $Self->{db}->can('sync_files_if_due') && $mine;
  # what the server supports (myRights.mayShare, the privilege tree), loaded
  # now: it may have to ask the server, which cannot happen in a transaction
  $Self->{db}->filenode_features() if $Self->{db}->can('filenode_features') && $mine;
  return $Self->_api_init($args);
}

sub api_FileNode_get {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  if ($args->{properties}) {
    my %known = map { $_ => 1 } @FILENODE_PROPERTIES;
    my @bad = grep { !$known{$_} } @{$args->{properties}};
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['properties'],
                                         description => "unknown properties: @bad"}]) if @bad;
  }

  my $rows = $Self->{db}->filenode_rows();
  my %byid = map { $_->{nodeid} => $_ } @$rows;

  my @want = defined $args->{ids} ? (map { $Self->idmap($_) // $_ } @{$args->{ids}})
                                  : (map { $_->{nodeid} } @$rows);
  my (%seen, @list, @notfound);
  for my $id (@want) {
    next if $seen{$id}++;
    my $row = $byid{$id} or do { push @notfound, $id; next };
    push @list, $row;
  }
  # draft S3.2.1 fetchParents: every ancestor, once
  if ($args->{fetchParents}) {
    my @requested = @list;   # walk a copy: the ancestors are appended to @list
    for my $row (@requested) {
      my $p = $row->{parentid};
      while (defined $p && !$seen{$p}++) {
        my $prow = $byid{$p} or last;
        push @list, $prow;
        $p = $prow->{parentid};
      }
    }
  }
  # the state read in the same transaction as the rows, so it matches them
  my $state = "$user->{jstateFileNode}";
  $Self->commit();

  my @objs = map { $Self->_filenode_object($_, \%byid) } @list;
  if ($args->{properties}) {
    my %want = map { $_ => 1 } 'id', @{$args->{properties}};
    @objs = map { my $o = $_; +{ map { ($_ => $o->{$_}) } grep { $want{$_} } keys %$o } } @objs;
  }
  return ['FileNode/get', { accountId => "$accountid", state => $state,
                            list => \@objs, notFound => [ map { "$_" } @notfound ] }];
}

sub api_FileNode_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateFileNode}";
  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $sinceState = $args->{sinceState};

  my $data = $Self->{db}->dget('jfilenodes', { jmodseq => ['>', $sinceState] },
                               'nodeid,active,jcreated,jmodseq');
  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    unless defined $data;
  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $sinceState, 'nodeid');
  return ['FileNode/changes', {
    accountId      => "$accountid",
    oldState       => "$sinceState",
    newState       => $newState,
    hasMoreChanges => ($partial ? JSON::true : JSON::false),
    created        => $created,
    updated        => $updated,
    destroyed      => $destroyed,
  }];
}


# draft S3.2.3.  Destroys run first, so a create or a move may take a name
# freed in the same call; then creates, ordered so "#cid" parents resolve;
# then updates (moves, content, properties); then the destroys and creates
# that depend on those moves (see below).  WebDAV has no transactions: each
# item succeeds or fails on its own (spec "Writes").
sub api_FileNode_set {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my $oldState = "$user->{jstateFileNode}";
  $Self->commit();
  return ['error', { type => 'stateMismatch' }]
    if defined $args->{ifInState} && $args->{ifInState} ne $oldState;
  my $onExists = $args->{onExists};
  # "unchanged" needs JMAP-CONDITIONAL, which the proxy does not offer
  return ['error', { type => 'invalidArguments', arguments => ['onExists'],
                     description => 'onExists must be null, "replace", "rename" or "newest"' }]
    if defined $onExists && (ref $onExists || $onExists !~ /^(?:replace|rename|newest)\z/);
  for my $arg (qw(create update)) {
    return ['error', { type => 'invalidArguments', arguments => [$arg] }]
      if defined $args->{$arg} && ref $args->{$arg} ne 'HASH';
  }
  return ['error', { type => 'invalidArguments', arguments => ['destroy'] }]
    if defined $args->{destroy} && ref $args->{destroy} ne 'ARRAY';
  my %opts = (onExists => $onExists,
              onDestroyRemoveChildren => $args->{onDestroyRemoveChildren} ? 1 : 0,
              ci => ($args->{compareCaseInsensitively} || $JMAP::FileNode::CAPS{caseInsensitiveNames}) ? 1 : 0);

  my $scoped_lock = $Self->{db}->begin_superlock();
  my $canon = JSON->new->canonical->allow_nonref;
  my $same = sub { $canon->encode($_[0]) eq $canon->encode($_[1]) };

  $Self->begin();
  my %before = map { $_->{nodeid} => $_ } @{ $Self->{db}->filenode_rows() };
  $Self->commit();

  # RFC 8620 S5.3: a patch may carry properties at their current values
  # (a whole object sent back); those change nothing, so they go
  my %update;
  for my $uid (keys %{ $args->{update} || {} }) {
    my $p = $args->{update}{$uid};
    my $row = $before{ $Self->idmap($uid) // $uid };
    if (ref $p eq 'HASH' && $row) {
      my $cur = $Self->_filenode_object($row, \%before);
      # with new content, type and size describe the new blob, whatever
      # the old ones were
      my %keep = exists $p->{blobId} && !$same->($p->{blobId}, $cur->{blobId}) ? (type => 1, size => 1) : ();
      $p = { map { ($_ => $p->{$_}) } grep { $keep{$_} || !exists $cur->{$_} || !$same->($p->{$_}, $cur->{$_}) } keys %$p };
    }
    $update{$uid} = $p;
  }

  # The set is judged by its final state (RFC 8620 S5.3; draft S3.2.3):
  # - a directory holding a node an update moves or renames is destroyed
  #   after the moves, so it is empty by then (its server-side member check
  #   still runs, and still guards against a stale mirror) -- inside
  #   update_filenodes, so a move into its name can follow it;
  # - a create whose name a node is moving away from, or a late destroy
  #   frees, or whose onExists "replace" would take such a directory, runs
  #   after the moves.
  # Everything else: destroys first (freeing names), then creates (so a
  # move may go into a new directory), then updates.
  # A node the client asked to move is a mover even when that update is
  # refused: a refused move leaves it where it is, and nothing in the call
  # may then delete it (update_filenodes and create_filenodes both refuse,
  # with nodeHasChildren or alreadyExists), so the partition here counts
  # every requested move, not only those that will succeed.
  my (@early, @late, %late_create, %mover);
  {
    my $ci = $opts{ci};
    my $key = sub { my $n = $_[0]; return $n unless $ci; utf8::upgrade($n); return lc $n };
    my %from;      # "parent\0name" each mover leaves
    my %holds;     # nodeid => 1 for each directory a mover is inside
    for my $uid (keys %update) {
      my $p = $update{$uid};
      next unless ref $p eq 'HASH' && (exists $p->{parentId} || exists $p->{name});
      my $row = $before{ $Self->idmap($uid) // $uid } or next;
      $mover{ $row->{nodeid} } = 1;
      $from{ ($row->{parentid} // '') . "\0" . $key->($row->{name}) } = 1;
      my %seen;
      for (my $a = $row->{parentid}; defined $a && !$seen{$a}++; $a = $before{$a} ? $before{$a}{parentid} : undef) {
        $holds{$a} = 1;
      }
    }
    for my $did (map { $Self->idmap($_) } @{ $args->{destroy} || [] }) {
      push @{ defined $did && $holds{$did} ? \@late : \@early }, $did;
    }
    for my $did (grep { defined && $before{$_} } @late) {
      $from{ ($before{$did}{parentid} // '') . "\0" . $key->($before{$did}{name}) } = 1;
    }
    my %at = map { (($_->{parentid} // '') . "\0" . $key->($_->{name}) => $_->{nodeid}) } values %before;
    my $create = $args->{create} || {};
    for my $cid (keys %$create) {
      my $c = $create->{$cid};
      next unless ref $c eq 'HASH' && defined $c->{parentId} && !ref $c->{parentId}
               && defined $c->{name} && !ref $c->{name} && $c->{parentId} !~ /^#/;
      my $k = ($Self->idmap($c->{parentId}) // '') . "\0" . $key->($c->{name});
      $late_create{$cid} = 1 if $from{$k} || (defined $at{$k} && $holds{ $at{$k} });
    }
    # a create inside a late one is late too
    my $more = 1;
    while ($more) {
      $more = 0;
      for my $cid (grep { !$late_create{$_} } keys %$create) {
        my $c = $create->{$cid};
        next unless ref $c eq 'HASH' && ($c->{parentId} // '') =~ /^#(.+)\z/s && $late_create{$1};
        $late_create{$cid} = $more = 1;
      }
    }
  }
  $opts{protect} = \%mover;   # create_filenodes: never replace a mover, or a directory one is still inside
  my $create = $args->{create} || {};
  my %early_create = map { ($_ => $create->{$_}) } grep { !$late_create{$_} } keys %$create;
  my %late_create_args = map { ($_ => $create->{$_}) } keys %late_create;

  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_filenodes(\@early, \%opts);
  my ($created, $notCreated, $also) = $Self->{db}->create_filenodes(\%early_create, sub { $Self->idmap(shift) }, \%opts);
  $Self->setid($_, $created->{$_}{nodeid}) for keys %$created;
  my ($updated, $notUpdated, $also2, $nd) = ({}, {}, [], {});
  ($updated, $notUpdated, $also2, $nd) = $Self->{db}->update_filenodes(\%update, sub { $Self->idmap(shift) },
                                                                        { %opts, late_destroy => \@late })
    if %update || @late;
  %$notDestroyed = (%$notDestroyed, %$nd);
  if (%late_create_args) {
    my ($c, $nc, $a) = $Self->{db}->create_filenodes(\%late_create_args, sub { $Self->idmap(shift) }, \%opts);
    $Self->setid($_, $c->{$_}{nodeid}) for keys %$c;
    %$created = (%$created, %$c);
    %$notCreated = (%$notCreated, %$nc);
    push @$also, @$a;
  }

  # created: the id plus every property the server set or defaulted, or
  # changed from what the client sent -- a renamed name, a resolved
  # "#cid" parent, a rounded timestamp (RFC 8620 S5.3)
  $Self->begin();
  my %after = map { $_->{nodeid} => $_ } @{ $Self->{db}->filenode_rows() };
  my %createdOut = map { ($_ => $after{ $created->{$_}{nodeid} } // ()) } keys %$created;
  $user = $Self->{db}->get_user();
  my $newState = "$user->{jstateFileNode}";
  $Self->commit();
  for my $cid (keys %createdOut) {
    my $full = $Self->_filenode_object($createdOut{$cid}, \%after);
    my $sent = $args->{create}{$cid};
    $createdOut{$cid} = { map { ($_ => $full->{$_}) }
                          grep { $_ eq 'id' || !exists $sent->{$_} || !$same->($sent->{$_}, $full->{$_}) } keys %$full };
  }
  # updated: every property that now differs from before the call and was
  # not set to that value by the patch (RFC 8620 S5.3) -- the blobId a
  # server that changes ETags on MOVE gave a renamed file, the myRights a
  # move into a shared directory brought, a size the server rounded, the
  # new "changed" -- on top of what update_filenodes reported itself
  for my $uid (keys %update) {
    my $id = $Self->idmap($uid) // $uid;
    next unless exists $updated->{$id} && $before{$id} && $after{$id};
    my $sent = $args->{update}{$uid};
    my $pre  = $Self->_filenode_object($before{$id}, \%before);
    my $post = $Self->_filenode_object($after{$id}, \%after);
    my %out = %{ $updated->{$id} || {} };
    for my $k (grep { $_ ne 'id' } keys %$post) {
      next if $same->($pre->{$k}, $post->{$k});
      next if exists $sent->{$k} && $same->($sent->{$k}, $post->{$k});
      next if !exists $sent->{$k} && grep { m{^\Q$k\E/} } keys %$sent;   # patched below it: as update_filenodes judged
      $out{$k} = $post->{$k};
    }
    $updated->{$id} = %out ? \%out : undef;
  }
  my %d;
  return ['FileNode/set', {
    accountId => "$accountid", oldState => $oldState, newState => $newState,
    created => _nullempty(\%createdOut), notCreated => _nullempty($notCreated),
    updated => _nullempty($updated), notUpdated => _nullempty($notUpdated),
    destroyed => _nullempty([ grep { !$d{$_}++ } map { "$_" } @$destroyed, @$also, @$also2 ]),
    notDestroyed => _nullempty($notDestroyed),
  }];
}

# The ids matching a /query, in order: filter and sort run on the objects
# FileNode/get returns (client-set dead properties overlaid).
sub _filenode_query_ids {
  my ($Self, $args, $rows) = @_;
  my %rowbyid = map { $_->{nodeid} => $_ } @$rows;
  my @objs = map { $Self->_filenode_object($_, \%rowbyid) } @$rows;
  my %byid = map { $_->{id} => $_ } @objs;
  # depth widens a top-level parentId / isTopLevel (see JMAP::FileNode::filter_match)
  my $ctx = { byid => \%byid, depth => $args->{depth} // 0 };
  my $filter = $args->{filter};
  my @m = grep { !$filter || JMAP::FileNode::filter_match($_, $filter, $ctx) } @objs;
  return [ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@m, $args->{sort} || [], \%byid) } ];
}

sub _filenode_query_problem {
  my ($Self, $args) = @_;
  if (defined $args->{filter} and my $why = JMAP::FileNode::filter_problem($args->{filter})) {
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['filter'], description => $why}]);
  }
  my %ok = map { $_ => 1 } @{ $JMAP::FileNode::CAPS{fileNodeQuerySortOptions} };
  for my $c (@{ $args->{sort} || [] }) {
    return $Self->_transError(['error', {type => 'unsupportedSort', sort => $c}]) unless $ok{$c->{property} // ''};
  }
  return ();
}

sub _filenode_query_params {
  my ($args) = @_;
  return { filter => $args->{filter}, sort => $args->{sort}, depth => $args->{depth} // 0 };
}

sub api_FileNode_query {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my @e = $Self->_filenode_query_problem($args);
  return @e if @e;
  my $rows = $Self->{db}->filenode_rows();
  my $state = "$user->{jstateFileNode}";
  $Self->commit();
  my $ids = $Self->_filenode_query_ids($args, $rows);
  $Self->{db}->save_query('FileNode', _filenode_query_params($args), $state, $ids);
  my ($start, $end) = $Self->_apply_window([ map { { id => $_ } } @$ids ], $args, sub { $_[0]{id} });
  return ['error', {type => 'anchorNotFound'}] unless defined $start;
  return ['FileNode/query', { accountId => $accountid, queryState => $state, canCalculateChanges => JSON::true,
                              position => $start + 0, total => scalar(@$ids), ids => [ @$ids[$start .. $end] ] }];
}

sub api_FileNode_queryChanges {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my @e = $Self->_filenode_query_problem($args);
  return @e if @e;
  my $state = "$user->{jstateFileNode}";
  my $since = $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    unless defined $since;
  my $params = _filenode_query_params($args);
  my $rows = $Self->{db}->filenode_rows();
  my %changed = map { $_->{nodeid} => 1 } @{ $Self->{db}->dget('jfilenodes', { jmodseq => ['>', $since] }, 'nodeid') };
  $Self->commit();
  # Under the tree sort a directory's descendants follow it: renaming or
  # moving the directory moves them too, though only its own row changed.
  if (grep { ($_->{property} // '') eq 'tree' } @{ $args->{sort} || [] }) {
    my %parent = map { $_->{nodeid} => $_->{parentid} } @$rows;
    for my $id (keys %parent) {
      next if $changed{$id};
      my %seen;
      for (my $p = $parent{$id}; defined $p && !$seen{$p}++; $p = $parent{$p}) {
        if ($changed{$p}) { $changed{$id} = 1; last }
      }
    }
  }
  # load_query and save_query open their own transactions
  my $old = $Self->{db}->load_query('FileNode', $params, $since);
  return ['error', {type => 'cannotCalculateChanges', newQueryState => $state}] unless $old;
  my $new = $Self->_filenode_query_ids($args, $rows);
  $Self->{db}->save_query('FileNode', $params, $state, $new);
  # every property is mutable, so a changed node is removed and re-added (RFC 8620 S5.6)
  my %oldset = map { $_ => 1 } @$old;
  my %newset = map { $_ => 1 } @$new;
  my @removed = grep { !$newset{$_} || $changed{$_} } @$old;
  my @added = map { { id => $new->[$_], index => $_ } } grep { !$oldset{$new->[$_]} || $changed{$new->[$_]} } 0 .. $#$new;
  return ['error', { type => 'tooManyChanges' }] if $args->{maxChanges} && @removed + @added > $args->{maxChanges};
  return ['FileNode/queryChanges', { accountId => $accountid, oldQueryState => "$since", newQueryState => $state,
                                     removed => \@removed, added => \@added, total => scalar(@$new) }];
}

1;
