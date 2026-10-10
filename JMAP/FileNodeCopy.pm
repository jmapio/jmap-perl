package JMAP::FileNodeCopy;
use strict;
use warnings;

# draft-ietf-jmap-filenode "FileNode/copy" between two accounts: a standard
# /copy (RFC 8620 S5.4) that also takes FileNode/set's onExists and
# onDestroyRemoveChildren.  The parent process runs it, so it MUST never
# block: every request goes through the injected $send (the proxy's
# send_backend_request: ($accountid, $command, $args, $cb, $errcb)), and
# the rest is bookkeeping.  No I/O of its own, so t/filenode-copy.t drives
# it against a fake.
#
#  1. The source: the nodes (FileNode/get), and each directory's
#     descendants in tree order, parents first (FileNode/query ancestorId,
#     sort "tree", calculateTotal, paged by position until the ids reach
#     the total; a missing total fails the item), then FileNode/get of
#     those in batches no larger than the source's maxObjectsInGet.
#  2. Every file's content: fetch_blobs from the source (d- blobIds are
#     pinned to the ETag the source listed: a file changed since is a 412,
#     so missing), store_blob into the destination.
#  3. One FileNode/set in the destination, each directory's contents created
#     under it with "#" references.  The copy keeps the source's own
#     properties (name, nodeType, type, target, created, modified, accessed,
#     executable, isSubscribed) under whatever the client's create gives;
#     not ids, blobId, size, myRights, role or shareWith, which are the
#     destination's.
#  4. With onExists "replace", "newest" or "unchanged", a directory with
#     contents is staged: created under a temporary name nothing else has,
#     then, once all of it is there, renamed to its name by one
#     FileNode/set update carrying the client's onExists (and
#     onDestroyRemoveChildren, ifUnchangedBy).  The node it replaces is
#     destroyed only by that rename, so a copy that fails part way never
#     costs it.
#
# Each create is all or nothing.  A node that cannot be read fails its
# whole item before the destination is touched.  A tree the destination
# accepts only in part, or whose staging rename fails, is removed again --
# by the explicit list of the nodes this copy created, never with
# onDestroyRemoveChildren, so a node someone else put in it meanwhile stays
# (and so does its directory) -- and the item is reported in notCreated,
# naming what failed.
#
# onSuccessDestroyOriginal destroys only items copied whole, listing every
# node of each (so it never uses onDestroyRemoveChildren: a node added to
# the source meanwhile makes its directory nodeHasChildren rather than
# being lost).  Between the content being read (2) and the source being
# destroyed there is a window: a file rewritten in it is destroyed with its
# new content, which was not copied.  WebDAV has no transactions to close
# it; a client that cares passes destroyFromIfInState, which the implicit
# FileNode/set checks against the state the source has then.

use JSON;

our $DEFAULT_MAX_GET = 500;
my @USING = ('urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:filenode');
my %STAGED_ONEXISTS = map { $_ => 1 } qw(replace newest unchanged);

# @ids in runs of at most $max.
sub chunks {
  my ($max, @ids) = @_;
  $max = $DEFAULT_MAX_GET unless defined $max && $max =~ /^\d+\z/ && $max > 0;
  my @c;
  push @c, [ splice @ids, 0, $max ] while @ids;
  return @c;
}

# The position of the next page of a directory's listing.
sub next_position { return scalar @{ $_[0]{ids} } }

# Add one FileNode/query response triple to a directory's listing
# ($l = { ids => [...] }).  Returns 'more' (ask for the page at
# next_position), 'done', or why the listing failed.
sub add_page {
  my ($l, $resp) = @_;
  return 'the source directory could not be listed'
    unless ref $resp eq 'ARRAY' && ($resp->[0] // '') eq 'FileNode/query' && ref $resp->[1] eq 'HASH';
  my $r = $resp->[1];
  return 'the source did not say how many nodes the directory holds'
    unless defined $r->{total} && !ref $r->{total} && $r->{total} =~ /^\d+\z/;
  my $changed = 'the source directory changed during the copy';
  return $changed if defined $l->{total} && $r->{total} != $l->{total};
  return $changed if defined $l->{state} && ($r->{queryState} // '') ne $l->{state};
  return $changed if ($r->{position} // 0) != next_position($l);
  $l->{total} //= $r->{total};
  $l->{state} //= $r->{queryState} // '';
  my $ids = ref $r->{ids} eq 'ARRAY' ? $r->{ids} : [];
  push @{ $l->{ids} }, @$ids;
  return $changed if next_position($l) > $l->{total};
  return 'done' if next_position($l) == $l->{total};
  return 'the source stopped returning nodes before the total it gave' unless @$ids;
  return 'more';
}

# A temporary name for a staged tree, unlike anything a client would pick.
sub staging_name { return sprintf('.jmap-copy-%08x%08x', int(rand(2**32)), int(rand(2**32))) }

sub copy {
  my (%o) = @_;
  my ($send, $args, $from, $to, $tag, $cb, $errcb) = @o{qw(send args from to tag cb errcb)};
  my $cids = $o{created_ids} || {};
  my $create = $args->{create} // {};
  return $cb->(['error', { type => 'invalidArguments', arguments => ['create'] }, $tag])
    unless ref $create eq 'HASH';
  my $fail = sub { $cb->(['error', { type => 'serverFail', description => "$_[0]" }, $tag]) };
  my $onexists = $args->{onExists};
  my $staging = defined $onexists && !ref $onexists && $STAGED_ONEXISTS{$onexists};
  my $ci = $args->{compareCaseInsensitively} ? 1 : 0;

  # a "#cid" from an earlier call in the request (RFC 8620 S5.3)
  my $deref = sub {
    my $v = shift;
    return $v unless defined $v && !ref $v && $v =~ /^#(.+)\z/s;
    return $cids->{$1};
  };
  my (%notcreated, %src_of, %parent_of);
  for my $cid (sort keys %$create) {
    my $c = $create->{$cid};
    my $id = ref $c eq 'HASH' ? $deref->($c->{id}) : undef;
    if (!defined $id || ref $id) {
      $notcreated{$cid} = { type => 'invalidProperties', properties => ['id'] };
      next;
    }
    if (exists $c->{parentId}) {
      my $p = $deref->($c->{parentId});
      if (defined $c->{parentId} && !defined $p) {
        $notcreated{$cid} = { type => 'invalidProperties', properties => ['parentId'],
                              description => 'no such creation id' };
        next;
      }
      $parent_of{$cid} = $p;
    }
    $src_of{$cid} = $id;
  }
  my @srcids = do { my %s; grep { !$s{$_}++ } map { $src_of{$_} } sort keys %src_of };

  my ($round, $listed, $plan);
  my %node;                                     # source id => the source's node
  my %list = map { ($_ => { ids => [] }) } @srcids;   # source id => its listing
  my $first = 1;

  # 1. the source: the nodes and their listings, page by page
  $round = sub {
    my @calls;
    push @calls, ['FileNode/get', { accountId => $from, ids => [@srcids] }, 'g'] if $first;
    my @q = grep { !defined $list{$_}{status} } @srcids;
    for my $k (0 .. $#q) {
      push @calls, ['FileNode/query', { accountId => $from, filter => { ancestorId => $q[$k] },
                                        sort => [ { property => 'tree' } ], calculateTotal => JSON::true,
                                        position => next_position($list{ $q[$k] }) }, "q$k"];
    }
    return $listed->() unless @calls;
    $send->($from, 'jmap', { using => [@USING], methodCalls => \@calls }, sub {
      my %r = map { ($_->[2] => $_) } @{ $_[0]{methodResponses} || [] };
      if ($first) {
        $first = 0;
        my $g = $r{g} or return $fail->('no FileNode/get answer from the source account');
        return $cb->(['error', $g->[1], $tag]) if $g->[0] eq 'error';
        return $cb->(['error', { type => 'stateMismatch' }, $tag])
          if defined $args->{ifFromInState} && $args->{ifFromInState} ne ($g->[1]{state} // '');
        %node = map { ($_->{id} => $_) } @{ $g->[1]{list} || [] };
        # only a directory has anything to list
        $list{$_}{status} = 'done' for grep { !$node{$_} || ($node{$_}{nodeType} // '') ne 'directory' } @srcids;
      }
      for my $k (0 .. $#q) {
        my $l = $list{ $q[$k] };
        next if defined $l->{status};
        my $s = add_page($l, $r{"q$k"});
        $l->{status} = $s unless $s eq 'more';
      }
      $round->();
    }, $errcb);
  };

  # ... then every descendant, in gets no larger than the source allows
  $listed = sub {
    my %seen;
    my @all = grep { !$seen{$_}++ } map { @{ $list{$_}{ids} } } grep { $list{$_}{status} eq 'done' } @srcids;
    my $fetch = sub {
      my ($max) = @_;
      my @runs = chunks($max, @all);
      my %got;
      my $next;
      $next = sub {
        return $plan->(\%got) unless @runs;
        my $run = shift @runs;
        $send->($from, 'jmap', { using => [@USING], methodCalls => [['FileNode/get', { accountId => $from, ids => $run }, 'd']] }, sub {
          my ($d) = grep { $_->[2] eq 'd' } @{ $_[0]{methodResponses} || [] };
          # what is missing fails its item (below)
          if ($d && $d->[0] eq 'FileNode/get') { $got{ $_->{id} } = $_ for @{ $d->[1]{list} || [] } }
          $next->();
        }, $errcb);
      };
      $next->();
    };
    return $fetch->($DEFAULT_MAX_GET) if @all <= $DEFAULT_MAX_GET;
    # the session says how many (a passthrough account's upstream); an
    # account without one of its own gets the conservative default
    $send->($from, 'session_caps', {}, sub {
      my $core = ((($_[0] || {})->{capabilities} || {})->{'urn:ietf:params:jmap:core'}) || {};
      $fetch->($core->{maxObjectsInGet});
    }, sub { $fetch->($DEFAULT_MAX_GET) });
  };

  $plan = sub {
    my ($got) = @_;
    my (%plan, %need, %path);   # cid => [ top, descendants... ]; blobId => 1; node id => path, for messages
    for my $cid (sort keys %src_of) {
      my $top = $node{ $src_of{$cid} } or do { $notcreated{$cid} = { type => 'notFound' }; next };
      my @desc;
      if (($top->{nodeType} // '') eq 'directory') {
        my $l = $list{ $top->{id} };
        unless ($l->{status} eq 'done') { $notcreated{$cid} = { type => 'serverFail', description => $l->{status} }; next }
        if (grep { !$got->{$_} } @{ $l->{ids} }) {
          $notcreated{$cid} = { type => 'serverFail', description => 'the source directory changed during the copy' };
          next;
        }
        @desc = map { $got->{$_} } @{ $l->{ids} };
      }
      $plan{$cid} = [ $top, @desc ];
      $path{ $top->{id} } = $top->{name};
      $path{ $_->{id} } = ($path{ $_->{parentId} // '' } // '...') . "/$_->{name}" for @desc;
      $need{ $_->{blobId} } = 1 for grep { ($_->{nodeType} // '') eq 'file' && defined $_->{blobId} } @{ $plan{$cid} };
    }
    my $files_of = sub { grep { ($_->{nodeType} // '') eq 'file' && defined $_->{blobId} } @{ $plan{ $_[0] } } };
    my $drop = sub {   # fail a whole item, naming the files whose blobs are in %$bad
      my ($cid, $bad, $what) = @_;
      my @names = sort map { $path{ $_->{id} } } grep { $bad->{ $_->{blobId} } } $files_of->($cid);
      $notcreated{$cid} = { type => 'serverFail', description => "$what: @names" };
      delete $plan{$cid};
    };

    # 2. the content
    my @bids = sort keys %need;
    my $after_fetch = sub {
      my ($blobs) = @_;
      $blobs ||= {};
      # a blob the source refused with a reason (over JMAP_FILES_MAX_BYTES)
      # fails its item with that reason; one it could not read, generically
      my %refused = map { ($_ => $blobs->{$_}{error}) } grep { $blobs->{$_} && $blobs->{$_}{error} } @bids;
      my %unread = map { ($_ => 1) } grep { !$blobs->{$_} } @bids;
      for my $cid (sort keys %plan) {
        my @why = map { $refused{$_} } grep { exists $refused{$_} } map { $_->{blobId} } $files_of->($cid);
        $drop->($cid, \%refused, 'the source content could not be read: ' . join('; ', @why)) if @why;
      }
      for my $cid (sort keys %plan) {
        $drop->($cid, \%unread, 'the source content could not be read (changed or gone since it was listed)')
          if grep { $unread{ $_->{blobId} } } $files_of->($cid);
      }
      my %live = map { ($_->{blobId} => 1) } map { $files_of->($_) } keys %plan;
      for my $bid (grep { $blobs->{$_} && !$refused{$_} && !$live{$_} } @bids) {
        unlink $blobs->{$bid}{path} if $blobs->{$bid}{is_temp};
      }
      my @queue = grep { $live{$_} } @bids;
      my %newblob;
      my $store_next;
      $store_next = sub {
        unless (@queue) {
          my %unstored = map { ($_ => 1) } grep { !defined $newblob{$_} } keys %live;
          for my $cid (sort keys %plan) {
            $drop->($cid, \%unstored, 'the content could not be stored in the destination account')
              if grep { $unstored{ $_->{blobId} } } $files_of->($cid);
          }
          return _write(%o, plan => \%plan, path => \%path, newblob => \%newblob, notcreated => \%notcreated,
                        parent_of => \%parent_of, staging => $staging, ci => $ci, fail => $fail);
        }
        my $bid = shift @queue;
        my $info = $blobs->{$bid};
        $send->($to, 'store_blob', $info, sub {
          $newblob{$bid} = ($_[0] || {})->{blobId};
          $store_next->();
        }, sub {
          unlink $info->{path} if $info->{is_temp};
          $store_next->();
        });
      };
      $store_next->();
    };
    return $after_fetch->({}) unless @bids;
    $send->($from, 'fetch_blobs', { ids => \@bids }, $after_fetch, $errcb);
  };

  $round->();
}

# 3 and 4: the destination.
sub _write {
  my (%o) = @_;
  my ($send, $args, $from, $to, $tag, $cb) = @o{qw(send args from to tag cb)};
  my ($plan, $path, $newblob, $notcreated, $parent_of, $fail) = @o{qw(plan path newblob notcreated parent_of fail)};
  my $create = $args->{create};
  my %pass = map { ($_ => $args->{$_}) }
             grep { defined $args->{$_} } qw(onExists onDestroyRemoveChildren compareCaseInsensitively ifUnchangedBy);

  my $carry = sub {
    my ($s) = @_;
    my %c = (name => $s->{name}, nodeType => $s->{nodeType});
    if (($s->{nodeType} // '') eq 'file') {
      $c{blobId} = $newblob->{ $s->{blobId} };
      $c{type} = $s->{type} if defined $s->{type};
    }
    $c{target} = $s->{target} if defined $s->{target};
    $c{$_} = $s->{$_} for grep { defined $s->{$_} } qw(created modified accessed executable isSubscribed);
    return \%c;
  };
  my (%sets, %keys_of, %srcids_of, %parentkey, %path_of_key, %final, %staged_name, %target, %dup_of);
  my $n = 0;
  CID: for my $cid (sort keys %$plan) {
    my ($top, @desc) = @{ $plan->{$cid} };
    my $tk = 'n' . $n++;
    my %key = ($top->{id} => $tk);
    my %over = map { ($_ => $create->{$cid}{$_}) } grep { $_ ne 'id' } keys %{ $create->{$cid} };
    $over{parentId} = $parent_of->{$cid} if exists $parent_of->{$cid};
    my %mine = ($tk => { %{ $carry->($top) }, %over });
    my $tkey;
    if ($o{staging}) {
      # two items aimed at one name would replace each other: the later
      # fails (the name is claimed below, once this item is sure to be sent)
      my $name = $mine{$tk}{name};
      $tkey = join "\0", map { ref $_ || !defined $_ ? '' : $o{ci} ? lc $_ : $_ } $mine{$tk}{parentId}, $name;
      if (my $first = $target{$tkey}) {
        $notcreated->{$cid} = { type => 'alreadyExists', description => "the copy of $first goes to the same name" };
        $dup_of{$cid} = $first;
        next CID;
      }
      if (@desc) {
        $final{$cid} = $name;
        $mine{$tk}{name} = $staged_name{$cid} = staging_name();
      }
    }
    $path_of_key{$tk} = $path->{ $top->{id} };
    for my $d (@desc) {
      my $pk = $key{ $d->{parentId} // '' };
      unless (defined $pk) {   # tree order puts parents first: the tree moved meanwhile
        $notcreated->{$cid} = { type => 'serverFail', description => 'the source directory changed during the copy' };
        delete $final{$cid};
        next CID;
      }
      my $k = 'n' . $n++;
      $key{ $d->{id} } = $k;
      $mine{$k} = { %{ $carry->($d) }, parentId => "#$pk" };
      $parentkey{$k} = $pk;
      $path_of_key{$k} = $path->{ $d->{id} };
    }
    $target{$tkey} = $cid if defined $tkey;
    %sets = (%sets, %mine);
    $keys_of{$cid} = [ $tk, map { $key{ $_->{id} } } @desc ];
    $srcids_of{$cid} = [ $top->{id}, map { $_->{id} } @desc ];
  }

  my %set_args = (accountId => $to, create => \%sets, %pass);
  $set_args{ifInState} = $args->{ifInState} if defined $args->{ifInState};
  my $jmap = sub {
    my ($call, $ok, $no) = @_;
    $send->($to, 'jmap', { using => [@USING], methodCalls => [$call] }, sub {
      my ($r) = grep { $_->[2] eq $call->[2] } @{ $_[0]{methodResponses} || [] };
      $r ? $ok->($r) : $no->('no answer from the destination account');
    }, sub { $no->("$_[0]") });
  };
  $jmap->(['FileNode/set', \%set_args, 's'], sub {
    my ($sresp) = @_;
    return $cb->(['error', $sresp->[1], $tag]) if $sresp->[0] eq 'error';
    my $sr = $sresp->[1];
    my ($ok, $nc) = ($sr->{created} || {}, $sr->{notCreated} || {});
    my $newState = $sr->{newState};
    my @destroyed = @{ ref $sr->{destroyed} eq 'ARRAY' ? $sr->{destroyed} : [] };
    my (%created, %rollback, %rename);   # cid => created object; cid => [ ids ]; top id => cid
    for my $cid (sort keys %keys_of) {
      my ($tk, @rest) = @{ $keys_of{$cid} };
      unless ($ok->{$tk}) {
        $notcreated->{$cid} = $nc->{$tk} || { type => 'serverFail', description => 'not created' };
        next;
      }
      my @made = map { $ok->{$_}{id} } grep { $ok->{$_} } $tk, @rest;
      if (grep { !$ok->{$_} } @rest) {
        # the nodes that failed in their own right, not for want of a parent
        my @bad = grep { !$ok->{$_} && $ok->{ $parentkey{$_} } } @rest;
        $notcreated->{$cid} = { type => 'serverFail',
          description => 'the destination refused part of the directory, so none of it was kept: '
                       . join('; ', map { "$path_of_key{$_}: " . (($nc->{$_} || {})->{type} // 'not created') } @bad) };
        $rollback{$cid} = \@made;
      }
      elsif (defined $final{$cid}) { $rename{ $ok->{$tk}{id} } = $cid; $rollback{$cid} = \@made }
      else                         { $created{$cid} = $ok->{$tk} }
    }

    my $finish = sub {
      for my $cid (keys %dup_of) {
        my $c = $created{ $dup_of{$cid} } or next;
        $notcreated->{$cid}{existingId} = $c->{id};
      }
      my $copy = ['FileNode/copy', {
        fromAccountId => $from,
        accountId     => $to,
        oldState      => $sr->{oldState},
        newState      => $newState,
        created       => %created     ? \%created     : undef,
        notCreated    => %$notcreated ? $notcreated   : undef,
        # draft, onExists "replace": the replaced node's id is listed as
        # destroyed; /copy has no such list, so it gets one
        (@destroyed ? (destroyed => \@destroyed) : ()),
      }, $tag];
      return $cb->($copy) unless $args->{onSuccessDestroyOriginal} && %created;
      # RFC 8620 S5.4: the implicit FileNode/set takes destroyFromIfInState
      # as its ifInState, and answers with the /copy's call id
      my %seen;
      my @del = grep { !$seen{$_}++ } map { @{ $srcids_of{$_} } } sort keys %created;
      my %d = (accountId => $from, destroy => \@del);
      $d{ifInState} = $args->{destroyFromIfInState} if defined $args->{destroyFromIfInState};
      my $lost = sub { $cb->([$copy, ['error', { type => 'serverFail',
        description => "destroying the originals: $_[0]" }, $tag]]) };
      $send->($from, 'jmap', { using => [@USING], methodCalls => [['FileNode/set', \%d, 'd']] }, sub {
        my ($dr) = grep { $_->[2] eq 'd' } @{ $_[0]{methodResponses} || [] };
        return $lost->('no answer from the source account') unless $dr;
        $cb->([$copy, [$dr->[0], $dr->[1], $tag]]);
      }, sub { $lost->("$_[0]") });
    };

    # 5. take back what must not stay: the explicit nodes this copy made
    # (listed parent first; the destroying server orders them itself)
    my $rollback = sub {
      my @cids = sort grep { !$created{$_} } keys %rollback;
      return $finish->() unless @cids;
      my @ids = map { @{ $rollback{$_} } } @cids;
      my $unremoved = sub {
        my %left = map { ($_ => 1) } @_;
        for my $cid (@cids) {
          my @l = grep { $left{$_} } @{ $rollback{$cid} } or next;
          $notcreated->{$cid}{description} = ($notcreated->{$cid}{description} // $notcreated->{$cid}{type})
                                           . " (and the partial copy could not be removed: @l)";
        }
      };
      $jmap->(['FileNode/set', { accountId => $to, destroy => \@ids }, 'r'], sub {
        my ($rr) = @_;
        if ($rr->[0] eq 'FileNode/set') {
          $unremoved->(keys %{ $rr->[1]{notDestroyed} || {} });
          $newState = $rr->[1]{newState} // $newState;
        }
        else { $unremoved->(@ids) }
        $finish->();
      }, sub { $unremoved->(@ids); $finish->() });
    };

    # 4. the staged trees take their names
    return $rollback->() unless %rename;
    my %update = map { ($_ => { name => $final{ $rename{$_} } }) } keys %rename;
    $jmap->(['FileNode/set', { accountId => $to, update => \%update, %pass }, 'u'], sub {
      my ($ur) = @_;
      my $u = $ur->[0] eq 'FileNode/set' ? $ur->[1] : {};
      for my $id (keys %rename) {
        my $cid = $rename{$id};
        if ($u->{updated} && exists $u->{updated}{$id}) {
          my ($tk) = @{ $keys_of{$cid} };
          $created{$cid} = { %{ $ok->{$tk} }, %{ $u->{updated}{$id} || {} } };
          delete $rollback{$cid};
        }
        else {
          $notcreated->{$cid} = ($u->{notUpdated} || {})->{$id}
            || ($ur->[0] eq 'error' ? { %{ $ur->[1] || {} } } : { type => 'serverFail', description => 'not renamed' });
        }
      }
      push @destroyed, @{ $u->{destroyed} } if ref $u->{destroyed} eq 'ARRAY';
      $newState = $u->{newState} // $newState;
      $rollback->();
    }, sub {
      # the answer was lost, not necessarily the rename: look before
      # taking anything back
      my $why = "renaming the copy: $_[0]";
      my $left = sub {   # $id where it is now, or gone: not ours to remove
        my ($id, $where) = @_;
        my $cid = $rename{$id};
        $notcreated->{$cid} = { type => 'serverFail', description => "$why; the copy, $id, is left $where" };
        delete $rollback{$cid};
      };
      $jmap->(['FileNode/get', { accountId => $to, ids => [ sort keys %rename ], properties => ['name'] }, 'v'], sub {
        my ($vr) = @_;
        unless ($vr->[0] eq 'FileNode/get') {
          $left->($_, 'in place, unchecked') for sort keys %rename;
          return $rollback->();
        }
        my %now = map { ($_->{id} => $_->{name}) } @{ $vr->[1]{list} || [] };
        for my $id (sort keys %rename) {
          my $cid = $rename{$id};
          my ($tk) = @{ $keys_of{$cid} };
          if (!defined $now{$id})                   { $left->($id, 'nowhere: it is gone') }
          elsif ($now{$id} eq $final{$cid})         { $created{$cid} = $ok->{$tk}; delete $rollback{$cid} }
          elsif ($now{$id} eq $staged_name{$cid})   { $notcreated->{$cid} = { type => 'serverFail', description => $why } }
          else                                      { $left->($id, "named $now{$id}") }
        }
        $rollback->();
      }, sub {
        $left->($_, 'in place, unchecked') for sort keys %rename;
        $rollback->();
      });
    });
  }, sub { $fail->($_[0]) });
}

1;
