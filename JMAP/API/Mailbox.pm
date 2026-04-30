package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Carp;
use Encode;

my $json = JSON::XS->new->utf8->canonical();

sub _makefullnames {
  my $data = shift;
  my %idmap = map { $_->{jmailboxid} => $_ } @$data;
  my %fullnames;

  delete $idmap{''};  # just in case

  foreach my $id (keys %idmap) {
    my $item = $idmap{$id};
    my @name;
    while ($item) {
      unshift @name, $item->{name};
      $item = $idmap{$item->{parentId}||''};
    }

    $fullnames{$id} = join('\1E', @name);
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
        $res = $a->{name} cmp $b->{name};
      }
      elsif ($field eq 'sortOrder') {
        $res = $a->{sortOrder} <=> $b->{sortOrder};
      }
      elsif ($field eq 'parent/name') {
        # magic synthentic field...
        $storage->{fullnames} ||= _makefullnames($storage->{data});
        $res = $storage->{fullnames}{$a->{jmailboxid}} cmp $storage->{fullnames}{$b->{jmailboxid}};
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

  if ($filter->{operator}) {
    if ($filter->{operator} eq 'NOT') {
      return not $Self->_mailbox_match($item, {operator => 'OR', conditions => $filter->{conditions}});
    }
    elsif ($filter->{operator} eq 'OR') {
      for my $cond (@{$filter->{conditions}}) {
        return 1 if $Self->_mailbox_match($item, $cond);
      }
      return 0;
    }
    elsif ($filter->{operator} eq 'AND') {
      for my $cond (@{$filter->{conditions}}) {
        return 0 unless $Self->_mailbox_match($item, $cond);
      }
      return 1;
    }
    die "Invalid operator $filter->{operator}";
  }

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

  return 1;
}

sub _mailbox_filter {
  my $Self = shift;
  my $data = shift;
  my $filter = shift;

  return [ grep { $Self->_mailbox_match($_, $filter) } @$data ];
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

sub _resolve_patch {
  my $Self = shift;
  my $update = shift;
  my $method = shift;
  foreach my $id (keys %$update) {
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
    foreach my $key (keys %keys) {
      $update->{$id}{$key} = $list->[0]{$key};
      _patchitem($update->{$id}, $_ => delete $update->{$id}{$_}) for @{$keys{$key}};
    }
  }
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
  $data = $Self->_mailbox_filter($data, $args->{filter}, $storage) if $args->{filter};

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
      canCalculateChanges => $JSON::false,
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
    canCalculateChanges => $JSON::false,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Mailbox_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateMailbox}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $sinceState = $args->{sinceState};

  my $data = $Self->{db}->dget('jmailboxes', { jmodseq => ['>', $sinceState] });

  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless defined $data;

  $Self->commit();

  my @created;
  my @updated;
  my @destroyed;
  my $onlyCounts = 1;
  foreach my $item (@$data) {
    if ($item->{active}) {
      if ($item->{jcreated} <= $sinceState) {
        push @updated, $item->{jmailboxid};
        $onlyCounts = 0 if $item->{jnoncountsmodseq} > $sinceState;
      }
      else {
        push @created, $item->{jmailboxid};
        $onlyCounts = 0;
      }
    }
    else {
      if ($item->{jcreated} <= $sinceState) {
        push @destroyed, $item->{jmailboxid};
      }
      # otherwise never seen
    }
  }
  $onlyCounts = 0 unless @updated;

  my @res = (['Mailbox/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    destroyed => [map { "$_" } @destroyed],
    hasMoreChanges => $partial ? JSON::true : JSON::false,
    updatedProperties => $onlyCounts ? ["totalEmails", "unreadEmails", "totalThreads", "unreadThreads"] : JSON::null,
  }]);

  return @res;
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

  ($created, $notCreated) = $Self->{db}->create_mailboxes($create, sub { $Self->idmap(shift) });
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Mailbox_get');
  ($updated, $notUpdated) = $Self->{db}->update_mailboxes($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_mailboxes($destroy, $args->{onDestroyRemoveEmails});

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
