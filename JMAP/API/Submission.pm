package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Date::Parse;
use Data::JSEmail;

my $json = JSON::XS->new->utf8->canonical();

sub _mk_submission_sort {
  my $items = shift // [];
  return undef unless ref($items) eq 'ARRAY';
  my @res;
  foreach my $item (@$items) {
    return undef unless defined $item;
    my ($field, $order) = split / /, $item;

    # invalid order
    return undef unless ($order eq 'asc' or $order eq 'desc');

    if ($field eq 'emailId') {
      push @res, "msgid $order";
    }
    elsif ($field eq 'threadId') {
      push @res, "thrid $order";
    }
    elsif ($field eq 'sentAt') {
      push @res, "sentat $order";
    }
    else {
      return undef; # invalid sort
    }
  }
  push @res, 'jsubid asc';
  return join(', ', @res);
}

sub _submission_filter {
  my $Self = shift;
  my $data = shift;
  my $filter = shift;
  my $storage = shift;

  if ($filter->{emailIds}) {
    return 0 unless grep { $_ eq $data->[2] } @{$filter->{emailIds}};
  }
  if ($filter->{threadIds}) {
    return 0 unless grep { $_ eq $data->[1] } @{$filter->{threadIds}};
  }
  if ($filter->{undoStatus}) {
    return 0 unless $filter->{undoStatus} eq 'final';
  }
  if ($filter->{before}) {
    my $time = str2time($filter->{before});
    return 0 unless $data->[3] < $time;
  }
  if ($filter->{after}) {
    my $time = str2time($filter->{after});
    return 0 unless $data->[3] >= $time;
  }

  # true if submitted
  return 1;
}

sub api_EmailSubmission_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateEmailSubmission}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['position']}])
    if $start < 0;

  my $sort = _mk_submission_sort($args->{sort});
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sort']}])
    unless $sort;

  my $data = $Self->get_submissions($sort);

  $data = $Self->_submission_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar(@$data);

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @list = map { $data->[$_] } $start..$end;

  $Self->commit();

  my @res;

  my $subids = [ map { "$_->[0]" } @list ];
  push @res, ['EmailSubmission/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    canCalculateChanges => $JSON::true,
    position => $start,
    total => $total,
    ids => $subids,
  }];

  return @res;
}

sub api_EmailSubmission_queryChanges {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateEmailSubmission}";
  my $sinceQueryState = $args->{sinceQueryState};

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    if not $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $sinceQueryState <= $user->{jdeletedmodseq});

  #properties: String[] A list of properties to fetch for each message.

  my $sort = _mk_submission_sort($args->{sort});
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sort']}])
    unless $sort;

  my $data = $Self->get_all_submissions($sort);

  $data = $Self->_submission_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar(@$data);

  $Self->commit();

  my @added;
  my @destroyed;

  my $index = 0;
  foreach my $item (@$data) {
    if ($item->[4] <= $sinceQueryState) {
      $index++ if $item->[5];
      next;
    }
    # changed
    push @destroyed, "$item->[0]";
    next unless $item->[5];
    push @added, { id => "$item->[0]", index => $index };
    $index++;
  }

  return ['EmailSubmission/queryChanges', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    oldQueryState => $sinceQueryState,
    newQueryState => $newQueryState,
    total => $total,
    destroyed => \@destroyed,
    added => \@added,
  }];
}

sub api_EmailSubmission_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateEmailSubmission}";

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['ids']}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  my %seenids;
  my %missingids;
  my @list;
  foreach my $subid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$subid};
    $seenids{$subid} = 1;
    my $data = $Self->{db}->dgetone('jsubmission', { jsubid => $subid });
    unless ($data) {
      $missingids{$subid} = 1;
      next;
    }

    my $thrid = $Self->{db}->dgetfield('jmessages', { msgid => $data->{msgid} }, 'thrid');

    my $item = {
      id => $subid,
      identityId => $data->{identity},
      emailId => $data->{msgid},
      threadId => $thrid,
      envelope => $data->{envelope} ? decode_json($data->{envelope}) : undef,
      sendAt => Data::JSEmail::isodate($data->{sendat}),
      undoStatus => $data->{status},
      deliveryStatus => undef,
      dsnBlobIds => [],
      mdnBlobIds => [],
    };

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    push @list, $item;
  }

  $Self->commit();

  return ['EmailSubmission/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_EmailSubmission_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateEmailSubmission}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $sinceState = $args->{sinceState};

  my $data = $Self->get_submission_changes($sinceState);

  $Self->commit();

  my $hasMore = 0;
  if ($args->{maxChanges} and $#$data >= $args->{maxChanges}) {
    $#$data = $args->{maxChanges} - 1;
    $newState = "$data->[-1][4]";
    $hasMore = 1;
  }

  my @created;
  my @updated;
  my @destroyed;

  foreach my $item (@$data) {
    # changed
    if ($item->[5]) {
      if ($item->[6] <= $args->{sinceState}) {
        push @updated, "$item->[0]";
      }
      else {
        push @created, "$item->[0]";
      }
    }
    else {
      if ($item->[6] <= $args->{sinceState}) {
        push @destroyed, "$item->[0]";
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['EmailSubmission/changes', {
    accountId => $accountid,
    oldState => $sinceState,
    newState => $newState,
    hasMoreChanges => $hasMore ? $JSON::true : $JSON::false,
    created => \@created,
    updated => \@updated,
    destroyed => \@destroyed,
    hasMoreChanges => JSON::false,
  }];

  return @res;
}

sub api_EmailSubmission_set {
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
  my $toUpdate = $args->{onSuccessUpdateEmail} || {};
  my $toDestroy = $args->{onSuccessDestroyEmail} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  # TODO: need to support ifInState for this sucker

  my %updateEmails;
  my @destroyEmails;

  my $scoped_lock = $Self->{db}->begin_superlock();

  # make sure our DB is up to date
  $Self->{db}->sync_folders();

  $Self->{db}->begin();
  my $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateEmailSubmission}";
  $Self->{db}->commit();

  ($created, $notCreated) = $Self->{db}->create_submissions($create, sub { $Self->idmap(shift) });
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_EmailSubmission_get');
  ($updated, $notUpdated) = $Self->{db}->update_submissions($update, sub { $Self->idmap(shift) });

  my @possible = ((map { $_->{id} } values %$created), (keys %$updated), @$destroy);

  # we need to convert all the IDs that were successfully created and updated plus any POSSIBLE
  # one that might be deleted into a map from id to messageid - after create and update, but
  # before delete.
  my $result = $Self->api_EmailSubmission_get({ids => \@possible, properties => ['emailId']});
  my %emailIds;
  if ($result->[0] eq 'EmailSubmission/get') {
    %emailIds = map { $_->{id} => $_->{emailId} } @{$result->[1]{list}};
  }

  # we can destroy now that we've read in the messageids of everything we intend to destroy... yay
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_submissions($destroy);

  # OK, we have data on all possible messages that need to be actioned after the messageSubmission
  # changes
  my %allowed = map { $_ => 1 } ((map { $_->{id} } values %$created), (keys %$updated), @$destroyed);

  foreach my $key (keys %$toUpdate) {
    my $id = $Self->idmap($key);
    next unless $allowed{$id};
    $updateEmails{$emailIds{$id}} = $toUpdate->{$key};
  }
  foreach my $key (@$toDestroy) {
    my $id = $Self->idmap($key);
    next unless $allowed{$id};
    push @destroyEmails, $emailIds{$id};
  }

  $Self->{db}->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateEmailSubmission}";
  $Self->{db}->commit();

  my @res;
  push @res, ['EmailSubmission/set', {
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

  if (%updateEmails or @destroyEmails) {
    push @res, $Self->api_Email_set({update => \%updateEmails, destroy => \@destroyEmails});
  }

  return @res;
}

1;
