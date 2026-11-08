package JMAP::API;
use strict;
use feature qw(fc);
use warnings;

use JSON::XS;
use JSON;
use Carp;
use Encode;
use JMAP::Collation;
use JMAP::QueryChanges;

my $json = JSON::XS->new->utf8->canonical();

sub _makefullnames {
  my $data = shift;
  my %idmap = map { $_->{jmailboxid} => $_ } @$data;
  my %fullnames;

  delete $idmap{''};  # just in case

  foreach my $id (keys %idmap) {
    my $item = $idmap{$id};
    my @name;
    my %seen;
    while ($item && !$seen{$item->{jmailboxid}}++) {
      unshift @name, $item->{name};
      $item = $idmap{$item->{parentId}||''};
    }

    # U+001E (RECORD SEPARATOR) sorts a parent before its children
    $fullnames{$id} = join("\x{1E}", @name);
  }

  return \%fullnames;
}

sub _mailbox_sort {
  my $Self = shift;
  my $data = shift;
  my $sortargs = shift;
  my $storage = shift;

  my %fieldmap = (
    name => ['name', 0],
    sortOrder => ['sortOrder', 1],
  );

  my @res = sort {
    foreach my $arg (@$sortargs) {
      my $res = 0;
      my $field = $arg->{property};
      if ($field eq 'name') {
        $res = JMAP::Collation::compare($arg->{collation}, $a->{name}, $b->{name},
                                        $storage->{collation_keys} //= {});
      }
      elsif ($field eq 'sortOrder') {
        $res = $a->{sortOrder} <=> $b->{sortOrder};
      }
      elsif ($field eq 'parent/name') {
        # magic synthentic field...
        $storage->{fullnames} ||= _makefullnames($storage->{data});
        $res = JMAP::Collation::compare($arg->{collation},
          $storage->{fullnames}{$a->{jmailboxid}}, $storage->{fullnames}{$b->{jmailboxid}},
          $storage->{collation_keys} //= {});
      }
      else {
        die "unknown field $field";
      }

      $res = -$res if defined($arg->{isAscending}) && !$arg->{isAscending};

      return $res if $res;
    }
    return $a->{jmailboxid} cmp $b->{jmailboxid}; # stable sort
  } @$data;

  return \@res;
}

sub _mailbox_match {
  my $Self = shift;
  my $item = shift;
  my $filter = shift;

  # RFC 8620 S5.5 FilterOperators
  return JMAP::API::_filter_matches($filter, sub { $Self->_mailbox_match($item, $_[0]) })
    if $filter->{operator};

  if (exists $filter->{hasAnyRole}) {
    if ($filter->{hasAnyRole}) {
      return 0 unless $item->{role};
    }
    else {
      return 0 if $item->{role};
    }
  }

  if (exists $filter->{hasRole}) {
    if ($filter->{hasRole}) {
      return 0 unless $item->{role};
    }
    else {
      return 0 if $item->{role};
    }
  }

  if (exists $filter->{parentId}) {
    if ($filter->{parentId}) {
      return 0 unless $item->{parentId};
      return 0 unless $item->{parentId} eq $filter->{parentId};
    }
    else {
      return 0 if $item->{parentId};
    }
  }

  if (exists $filter->{isSubscribed}) {
    if ($filter->{isSubscribed}) {
      return 0 unless $item->{isSubscribed};
    }
    else {
      return 0 if $item->{isSubscribed};
    }
  }

  if (exists $filter->{name}) {
    # RFC 8621 S2.3: "The Mailbox name contains the given string"
    return 0 unless defined $item->{name};
    my $name = eval { Encode::decode_utf8($item->{name}) } // $item->{name};
    return 0 unless index(fc($name), fc($filter->{name} // '')) >= 0;
  }

  if (exists $filter->{role}) {
    if (defined $filter->{role}) {
      return 0 unless defined $item->{role};
      return 0 unless $item->{role} eq $filter->{role};
    }
    else {
      return 0 if defined $item->{role};
    }
  }

  return 1;
}

sub _mailbox_filter {
  my ($Self, $data, $filter, $filter_as_tree) = @_;

  my @matched = grep { $Self->_mailbox_match($_, $filter) } @$data;
  return \@matched unless $filter_as_tree;

  # RFC 8621 S2.3: "a Mailbox is only included in the query if all its
  # ancestors are also included in the query according to the filter."
  my %idmap   = map { $_->{jmailboxid} => $_ } @$data;
  my %matched = map { $_->{jmailboxid} => 1 } @matched;
  my @result;
  ITEM: for my $item (@matched) {
    my %seen;
    for (my $pid = $item->{parentId}; $pid && !$seen{$pid}++; $pid = $idmap{$pid}{parentId}) {
      next ITEM unless $matched{$pid} && $idmap{$pid};
    }
    push @result, $item;
  }
  return \@result;
}

# Re-order a flat sorted list so each parent appears immediately before its children
# (depth-first pre-order traversal, siblings in their existing sort order).
sub _sort_as_tree {
  my ($data) = @_;
  my %idmap    = map { $_->{jmailboxid} => $_ } @$data;
  my %children;
  my @roots;
  for my $item (@$data) {
    my $pid = $item->{parentId} // '';
    if ($pid && $idmap{$pid}) {
      push @{$children{$pid}}, $item;
    } else {
      push @roots, $item;
    }
  }
  my @result;
  my @stack = @roots;
  while (@stack) {
    my $item = shift @stack;
    push @result, $item;
    unshift @stack, @{$children{$item->{jmailboxid}} // []};
  }
  return \@result;
}

sub _patchitem {
  my $target = shift;
  my $key = shift;
  my $value = shift;

  if ($key =~ s{^([^/]+)/}{}) {
    my $token = $1;
    $token =~ s{~1}{/}g;
    $token =~ s{~0}{~}g;
    if (ref($target) eq 'ARRAY') {
      return _patchitem($target->[$token], $key, $value);
    }
    Carp::confess "missing patch target for '$token'" unless ref($target) eq 'HASH';
    # Auto-vivify missing intermediate hash (RFC 8620 JSON Pointer semantics)
    $target->{$token} = {} unless ref($target->{$token});
    return _patchitem($target->{$token}, $key, $value);
  }

  $key =~ s{~1}{/}g;
  $key =~ s{~0}{~}g;

  if (ref($target) eq 'ARRAY') {
    if (defined $value) { $target->[$key] = $value }
    else                { splice @$target, $key, 1  }
  }
  else {
    Carp::confess "missing patch target" unless ref($target) eq 'HASH';
    if (defined $value) { $target->{$key} = $value  }
    else                { delete $target->{$key}     }
  }
}

# True if a PatchObject breaks a rule of RFC 8620 S5.3, which "MUST be
# rejected with an invalidPatch error": a pointer that is the prefix of
# another, a part before the last that does not "already exist on the object
# being patched", or a pointer that references inside an array. $current
# holds (at least) the object's values for the top-level properties named.
sub _patch_invalid {
  my ($patch, $current) = @_;
  for my $key (keys %$patch) {
    my @parts = map { s{~1}{/}gr =~ s{~0}{~}gr } split m{/}, $key, -1;
    next if @parts < 2;
    # an ancestor of this pointer patched too
    my @raw = split m{/}, $key, -1;
    for my $n (1 .. $#raw) {
      return 1 if exists $patch->{ join '/', @raw[0 .. $n - 1] };
    }
    my $target = $current;
    pop @parts;
    for my $part (@parts) {
      return 1 unless ref $target eq 'HASH' && defined $target->{$part};
      $target = $target->{$part};
    }
    return 1 unless ref $target eq 'HASH';   # inside an array, or a scalar
  }
  return 0;
}

# Turn each PatchObject in $update into a full value for every top-level
# property it patches. Returns { id => SetError } for the patches that break
# RFC 8620 S5.3's rules; those are taken out of $update, and the caller puts
# them in notUpdated.
sub _resolve_patch {
  my $Self = shift;
  my $update = shift;
  my $method = shift;
  my %invalid;
  foreach my $id (keys %$update) {
    next unless ref $update->{$id} eq 'HASH';
    my %keys;
    foreach my $key (sort keys %{$update->{$id}}) {
      next unless $key =~ m{([^/]+)/};
      push @{$keys{$1}}, $key;
    }
    next unless keys %keys; # nothing patched in this one
    my $data = $Self->$method({ids => [$id], properties => [keys %keys]});
    my $list = $data->[1]{list};
    # XXX - if nothing in the list we SHOULD abort
    next unless $list->[0];
    if (_patch_invalid($update->{$id}, $list->[0])) {
      delete $update->{$id};
      $invalid{$id} = { type => 'invalidPatch' };
      next;
    }
    foreach my $key (keys %keys) {
      $update->{$id}{$key} = $list->[0]{$key};
      _patchitem($update->{$id}, $_ => delete $update->{$id}{$_}) for @{$keys{$key}};
    }
  }
  return \%invalid;
}

sub api_Mailbox_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateMailbox}";

  my $data = $Self->{db}->dget('jmailboxes', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_->{jmailboxid} => 1 } @$data;
  }

  my %byrole = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$data;

  my @list;

  foreach my $item (@$data) {
    next unless delete $want{$item->{jmailboxid}};

    my %rights = map { $_ => ($item->{$_} ? $JSON::true : $JSON::false) } qw(mayReadItems mayAddItems mayRemoveItems maySetSeen maySetKeywords mayCreateChild mayRename mayDelete maySubmit mayAdmin);
    my %rec = (
      id => "$item->{jmailboxid}",
      name => Encode::decode_utf8($item->{name}),
      parentId => $item->{parentId},
      role => $item->{role},
      sortOrder => $item->{sortOrder}||0,
      (map { $_ => $item->{$_} || 0 } qw(totalEmails unreadEmails totalThreads unreadThreads)),
      myRights => \%rights,
      (map { $_ => ($item->{$_} ? $JSON::true : $JSON::false) } qw(isSubscribed)),
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }

  $Self->commit();

  my %missingids = %want;

  return ['Mailbox/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Mailbox_query {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateMailbox}";

  my %valid_sort = map { $_ => 1 } qw(name sortOrder parent/name);
  for my $arg (@{$args->{sort} // []}) {
    return $Self->_transError(['error', {type => 'unsupportedSort', sort => $arg}])
      unless $valid_sort{$arg->{property} // ''};
  }

  my $data = $Self->{db}->dget('jmailboxes', { active => 1 });

  $Self->commit();

  my $storage = { data => $data };
  $data = $Self->_mailbox_sort($data, $args->{sort}, $storage);
  $data = $Self->_mailbox_filter($data, $args->{filter}, $args->{filterAsTree}) if $args->{filter};
  $data = _sort_as_tree($data) if $args->{sortAsTree};

  $Self->{db}->save_query('Mailbox', {
    filter       => $args->{filter},
    filterAsTree => $args->{filterAsTree} ? 1 : 0,
    sort         => $args->{sort},
    sortAsTree   => $args->{sortAsTree}   ? 1 : 0,
  }, $newQueryState, [map { $_->{jmailboxid} } @$data]);

  my $total = scalar @$data;

  if (defined $args->{limit} && $args->{limit} < 0) {
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['limit']}]);
  }

  my $start = $args->{position} || 0;

  if ($args->{anchor}) {
    # need to calculate the position
    for (0..$#$data) {
      next unless $data->[$_]{jmailboxid} eq $args->{anchor};
      $start = $_ + ($args->{anchorOffset} || 0);
      $start = 0 if $start < 0;
      goto gotit;
    }
    return $Self->_transError(['error', {type => 'anchorNotFound'}]);
  }

  gotit:
  # Handle negative positions (count from end)
  if ($start < 0) {
    $start = $total + $start;
    $start = 0 if $start < 0;
  }

  # Position beyond total = no results, position clamped to 0
  if ($start >= $total) {
    my @res;
    push @res, ['Mailbox/query', {
      accountId => $accountid,
      filter => $args->{filter},
      sort => $args->{sort},
      queryState => $newQueryState,
      canCalculateChanges => $JSON::true,
      position => 0,
      total => $total,
      ids => [],
    }];
    return @res;
  }

  my $end = defined($args->{limit}) ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;
  $end = $start - 1 if $end < $start;  # limit 0

  my @result = ($start <= $end) ? map { $data->[$_]{jmailboxid} } $start..$end : ();

  my @res;
  push @res, ['Mailbox/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    canCalculateChanges => $JSON::true,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Mailbox_changes {
  my ($Self, $args) = @_;
  return $Self->_table_changes($args, method => 'Mailbox/changes',
    table => 'jmailboxes', key => 'jmailboxid', state => 'jstateMailbox', cols => ['jnoncountsmodseq'],
    # RFC 8621 S2.2: when only the counts changed, say so
    finish => sub {
      my ($res, $rows, $since) = @_;
      my $onlyCounts = @{ $res->{updated} } && !@{ $res->{created} }
        && !grep { $_->{active} && $_->{jcreated} <= $since && ($_->{jnoncountsmodseq} // 0) > $since } @$rows;
      $res->{updatedProperties} = $onlyCounts ? [qw(totalEmails unreadEmails totalThreads unreadThreads)] : JSON::null;
    });
}

sub api_Mailbox_queryChanges {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateMailbox}";
  my $sinceQueryState = $args->{sinceQueryState};

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    unless defined $sinceQueryState;
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $sinceQueryState <= $user->{jdeletedmodseq});

  my %valid_sort = map { $_ => 1 } qw(name sortOrder parent/name);
  for my $arg (@{$args->{sort} // []}) {
    return $Self->_transError(['error', {type => 'unsupportedSort', sort => $arg}])
      unless $valid_sort{$arg->{property} // ''};
  }

  my $data = $Self->{db}->dget('jmailboxes', { active => 1 });

  $Self->commit();

  my $qparams = {
    filter       => $args->{filter},
    filterAsTree => $args->{filterAsTree} ? 1 : 0,
    sort         => $args->{sort},
    sortAsTree   => $args->{sortAsTree}   ? 1 : 0,
  };
  my $old_ids = $Self->{db}->load_query('Mailbox', $qparams, $sinceQueryState);

  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    unless defined $old_ids;

  my $storage = { data => $data };
  $data = $Self->_mailbox_sort($data, $args->{sort}, $storage);
  $data = $Self->_mailbox_filter($data, $args->{filter}, $args->{filterAsTree}) if $args->{filter};
  $data = _sort_as_tree($data) if $args->{sortAsTree};

  my @new_ids = map { $_->{jmailboxid} } @$data;

  # Every Mailbox property the sort and filter use (name, sortOrder, parentId,
  # role, isSubscribed) is mutable, so each mailbox changed since the old
  # state is reported (RFC 8620 S5.6). The counts don't take part, so a
  # mailbox that only got new mail (jmodseq, not jnoncountsmodseq) doesn't.
  my %changed = map { $_->{jmailboxid} => 1 }
                grep { ($_->{jnoncountsmodseq} // $_->{jmodseq} // 0) > $sinceQueryState } @$data;
  my ($removed, $added) = JMAP::QueryChanges::diff($old_ids, \@new_ids, \%changed);

  return $Self->_transError(['error', {type => 'tooManyChanges', newQueryState => $newQueryState}])
    if $args->{maxChanges} and @$removed + @$added > $args->{maxChanges};

  $Self->{db}->save_query('Mailbox', $qparams, $newQueryState, \@new_ids);

  return ['Mailbox/queryChanges', {
    accountId     => $accountid,
    filter        => $args->{filter},
    sort          => $args->{sort},
    oldQueryState => "$sinceQueryState",
    newQueryState => $newQueryState,
    total         => scalar(@new_ids),
    removed       => [map { "$_" } @$removed],
    added         => $added,
  }];
}

# RFC 8621 S2: a role is a use attribute from the IANA "IMAP Mailbox Name
# Attributes" registry, lowercased, or "inbox".
my %MAILBOX_ROLES = map { $_ => 1 } qw(
  inbox all archive drafts flagged important junk sent trash snoozed scheduled memos
);

# The invalid properties of a Mailbox create or update; $roles maps each role
# in use to the mailbox holding it.
sub _mailbox_bad_props {
  my ($mailbox, $jid, $roles) = @_;
  my @bad;
  if (exists $mailbox->{name} || !defined $jid) {
    my $name = $mailbox->{name};
    # "at least 1 character", and maxSizeMailboxName (490) is in octets
    push @bad, 'name' unless defined $name && !ref $name && length $name
                             && length(Encode::encode_utf8($name)) <= 490;
  }
  if (exists $mailbox->{sortOrder}) {
    my $so = $mailbox->{sortOrder};
    # "0 <= sortOrder < 2^31"
    push @bad, 'sortOrder'
      unless defined $so && !ref $so && "$so" =~ /^\d+$/ && $so < 2**31;
  }
  if (defined $mailbox->{role}) {
    my $role = $mailbox->{role};
    # a registered role, and "no two Mailboxes ... with the same role"
    push @bad, 'role'
      if ref $role || !$MAILBOX_ROLES{$role}
         || ($roles->{$role} && (!defined $jid || $roles->{$role} ne $jid));
  }
  return @bad;
}

sub api_Mailbox_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  # make sure our DB is up to date - happy to enforce this because folder names
  # are a unique namespace, so we should try to minimise the race time
  $Self->{db}->sync_folders();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();
  $oldState = "$user->{jstateMailbox}";

  return $Self->_transError(['error', {type => 'stateMismatch', oldState => $oldState, newState => $oldState}])
    if defined $args->{ifInState} and $args->{ifInState} ne $oldState;

  # Reject invalid name, sortOrder and role before anything reaches IMAP.
  $Self->begin();
  my $existing = $Self->{db}->dget('jmailboxes', { active => 1 }, 'jmailboxid,role,name,parentId');
  $Self->commit();
  my %roles = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$existing;
  my %byid  = map { $_->{jmailboxid} => $_ } @$existing;
  # RFC 8621 S2: "There MUST NOT be two sibling Mailboxes with both the same
  # parent and the same name."  Names are stored as UTF-8 octets.
  my %sibling;
  $sibling{$_->{parentId} // ''}{$_->{name} // ''} = $_->{jmailboxid} for @$existing;
  my $sibling_clash = sub {
    my ($jid, $name, $parent) = @_;
    my $holder = $sibling{$parent // ''}{Encode::encode_utf8($name)};
    return $holder && (!defined $jid || $holder ne $jid);
  };
  my (%badCreate, %badUpdate);
  $create = { %$create };
  for my $cid (sort keys %$create) {
    next unless ref $create->{$cid} eq 'HASH';
    my @bad = _mailbox_bad_props($create->{$cid}, undef, \%roles);
    push @bad, 'name' if !grep({ $_ eq 'name' } @bad)
      && $sibling_clash->(undef, $create->{$cid}{name}, $Self->idmap($create->{$cid}{parentId}));
    if (@bad) {
      $badCreate{$cid} = { type => 'invalidProperties', properties => \@bad };
      delete $create->{$cid};
    }
    elsif (defined $create->{$cid}{role}) {
      $roles{$create->{$cid}{role}} = "#$cid";
    }
  }

  ($created, $notCreated) = $Self->{db}->create_mailboxes($create, sub { $Self->idmap(shift) });
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  for my $cid (keys %$created) {
    my $role = $create->{$cid}{role} // next;
    $roles{$role} = $created->{$cid}{id};
  }

  my $patchInvalid = $Self->_resolve_patch($update, 'api_Mailbox_get');
  $update = { %$update };
  for my $jid (sort keys %$update) {
    next unless ref $update->{$jid} eq 'HASH';
    my $id = $Self->idmap($jid);
    my @bad = _mailbox_bad_props($update->{$jid}, $id, \%roles);
    my $patch = $update->{$jid};
    if (($byid{$id} && (exists $patch->{name} || exists $patch->{parentId}))
        && !grep { $_ eq 'name' } @bad) {
      my $name   = exists $patch->{name} ? $patch->{name}
                 : Encode::decode_utf8($byid{$id}{name} // '');
      my $parent = exists $patch->{parentId} ? $Self->idmap($patch->{parentId})
                 : $byid{$id}{parentId};
      push @bad, 'name' if $sibling_clash->($id, $name, $parent);
    }
    if (@bad) {
      $badUpdate{$jid} = { type => 'invalidProperties', properties => \@bad };
      delete $update->{$jid};
    }
  }

  ($updated, $notUpdated) = $Self->{db}->update_mailboxes($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_mailboxes($destroy, $args->{onDestroyRemoveEmails});
  $notCreated = { %{$notCreated || {}}, %badCreate };
  $notUpdated = { %{$notUpdated || {}}, %badUpdate };
  $notUpdated = { %{$notUpdated || {}}, %$patchInvalid } if %$patchInvalid;   # RFC 8620 S5.3

  # RFC 8620 S5.3: created carries every property the server set or
  # defaulted, which here is everything the client did not send.
  if ($created && %$created) {
    my ($get) = $Self->api_Mailbox_get({ ids => [ map { $_->{id} } values %$created ] });
    my %byid = map { $_->{id} => $_ } @{$get->[1]{list} || []};
    for my $cid (keys %$created) {
      my $full = $byid{$created->{$cid}{id}} or next;
      for my $prop (keys %$full) {
        $created->{$cid}{$prop} = $full->{$prop}
          unless exists $create->{$cid}{$prop} && $prop ne 'id';
      }
    }
  }

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  $newState = "$user->{jstateMailbox}";

  my @res;
  push @res, ['Mailbox/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => _nullempty($created),
    notCreated => _nullempty($notCreated),
    updated => _nullempty($updated),
    notUpdated => _nullempty($notUpdated),
    destroyed => _nullempty($destroyed),
    notDestroyed => _nullempty($notDestroyed),
  }];

  return @res;
}

1;
