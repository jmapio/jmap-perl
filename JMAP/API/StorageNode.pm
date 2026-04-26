package JMAP::API;
use strict;
use warnings;

use JSON;

sub dummy_node_matches {
  my $filter = shift;
  my $node = shift;

  return 1 unless $filter;
  return 1 unless $filter->{parentIds};

  foreach my $parentId (@{$filter->{parentIds}}) {
    if (not defined $parentId) {
      return 1 if not defined $node->{parentId};
    }
    else {
      return 1 if (defined $node->{parentId} and $parentId eq $node->{parentId});
    }
  }

  return 0;
}

sub dummy_storage_node_data {
  my $time = '2018-02-01T00:00:00Z';
  my @data = (
    {
      id => 'root',
      parentId => undef,
      blobId => undef,
      name => '/',
      created => $time,
      modified => $time,
      size => 0,
      type => undef,
      mayUpdate => $JSON::true,
      mayRename => $JSON::true,
      mayDelete => $JSON::true,
      mayCreateChild => $JSON::true,
      mayAddItems => $JSON::true,
      mayReadItems => $JSON::true,
      mayRemoveItems => $JSON::true,
    },
    {
      id => 'trash',
      parentId => undef,
      blobId => undef,
      name => 'Trash',
      created => $time,
      modified => $time,
      size => 0,
      type => undef,
      mayUpdate => $JSON::true,
      mayRename => $JSON::true,
      mayDelete => $JSON::true,
      mayCreateChild => $JSON::true,
      mayAddItems => $JSON::true,
      mayReadItems => $JSON::true,
      mayRemoveItems => $JSON::true,
    },
  );

  return @data;
}

sub api_StorageNode_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = 'dummy';

  my $data = [grep { dummy_node_matches($args->{filter}, $_) } dummy_storage_node_data()];

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['position']}])
    if $start < 0;

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{id} } $start..$end;

  $Self->commit();

  return ['StorageNode/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];
}

sub api_StorageNode_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = 'dummy';

  #properties: String[] A list of properties to fetch for each message.

  my $data = { map { $_->{id} => $_ } dummy_storage_node_data() };

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = %$data;
  }

  my @list;
  foreach my $id (keys %want) {
    next unless $data->{$id};
    delete $want{$id};

    my $item = $data->{$id};

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $id;

    push @list, $item;
  }
  $Self->commit();

  my %missingids = %want;

  return ['StorageNode/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

1;
