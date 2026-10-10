package JMAP::API;
use strict;
use JMAP::Collation;
use warnings;
use Digest::SHA qw(sha1_hex);
use JSON;

# IMAP resource → JMAP mapping
my %RESOURCE_MAP = (
  STORAGE  => { type => 'octets', scale => 1024, types => ['Email', 'Thread', 'Mailbox', 'EmailSubmission'] },
  MESSAGES => { type => 'count',  scale => 1,    types => ['Email'] },
);

sub _quota_state {
  my ($quotas) = @_;
  # Use sprintf '%d' to avoid setting SvPOK on the numeric scalars (string
  # interpolation would corrupt the JSON type, causing JSON::XS to encode
  # used/hardLimit as strings instead of numbers).
  return sha1_hex(join(',', map { sprintf('%s=%d/%d', $_->{id}, $_->{used}, $_->{hardLimit}) }
                              sort { $a->{id} cmp $b->{id} } @$quotas));
}

sub _quota_to_jmap {
  my ($raw, $name) = @_;
  my $resource = uc($raw->{resource});
  my $info  = $RESOURCE_MAP{$resource}
           || { type => lc($resource), scale => 1, types => ['Email'] };
  my $scale = $info->{scale};
  return {
    id           => "$raw->{root}:$resource",
    resourceType => $info->{type},
    used         => int($raw->{used}  * $scale),
    hardLimit    => int($raw->{limit} * $scale),
    scope        => 'account',
    name         => $name || $raw->{root} || 'default',
    types        => $info->{types},
  };
}

sub _get_all_quotas {
  my ($Self, $user) = @_;
  my $name = $user->{email} // '';
  # Commit before backend_cmd (which requires no open transaction)
  $Self->commit();
  my $raw = eval { $Self->{db}->backend_cmd('get_quota') } || [];
  return map { _quota_to_jmap($_, $name) } @$raw;
}

sub api_Quota_get {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my @all = _get_all_quotas($Self, $user);

  my (@list, @not_found);
  if ($args->{ids}) {
    my %by_id = map { $_->{id} => $_ } @all;
    for my $id (@{$args->{ids}}) {
      exists $by_id{$id} ? push(@list, $by_id{$id}) : push(@not_found, $id);
    }
  } else {
    @list = @all;
  }

  if ($args->{properties}) {
    my %want = (id => 1, map { $_ => 1 } @{$args->{properties}});
    @list = map { my $q = $_; +{ map { exists $q->{$_} ? ($_ => $q->{$_}) : () } keys %want } } @list;
  }

  return ['Quota/get', {
    accountId => $accountid,
    state     => _quota_remember($Self, \@all),
    list      => \@list,
    notFound  => \@not_found,
  }];
}

# Every state the account has been seen in keeps a snapshot of each quota's
# value, so /changes and /queryChanges can diff against it (for as long as
# the jqueries cache keeps it: an hour).
sub _quota_snapshot {
  my ($quotas) = @_;
  return { map { $_->{id} => sprintf('%d/%d', $_->{used}, $_->{hardLimit}) } @$quotas };
}

sub _quota_remember {
  my ($Self, $quotas) = @_;
  my $state = _quota_state($quotas);
  $Self->{db}->save_query('QuotaState', {}, $state, _quota_snapshot($quotas));
  return $state;
}

sub api_Quota_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my @all   = _get_all_quotas($Self, $user);
  my $state = _quota_remember($Self, \@all);
  my $since = $args->{sinceState} // '';
  my $old   = $since eq $state ? _quota_snapshot(\@all)
            : $Self->{db}->load_query('QuotaState', {}, $since);
  return ['error', {type => 'cannotCalculateChanges', newState => $state}] unless $old;

  # RFC 9425 S4.3: a quota whose usage changed is updated
  my $now = _quota_snapshot(\@all);
  my @created   = sort grep { !exists $old->{$_} } keys %$now;
  my @updated   = sort grep { exists $old->{$_} && $old->{$_} ne $now->{$_} } keys %$now;
  my @destroyed = sort grep { !exists $now->{$_} } keys %$old;
  if ($args->{maxChanges} && @created + @updated + @destroyed > $args->{maxChanges}) {
    return ['error', {type => 'cannotCalculateChanges', newState => $state}];
  }
  return ['Quota/changes', {
    accountId      => $accountid,
    oldState       => $since,
    newState       => $state,
    hasMoreChanges => JSON::false,
    created        => \@created,
    updated        => \@updated,
    destroyed      => \@destroyed,
  }];
}

# The ids of the quotas matching a Quota/query filter, in its sort order.
sub _quota_query_ids {
  my ($Self, $args, $all) = @_;
  my $filter = $args->{filter} || {};
  my @filtered = grep {
    my $q = $_;
    (!defined $filter->{name}         || index($q->{name}, $filter->{name}) >= 0) &&
    (!defined $filter->{scope}        || ($q->{scope} // '') eq $filter->{scope}) &&
    (!defined $filter->{resourceType} || $q->{resourceType} eq $filter->{resourceType}) &&
    (!defined $filter->{type}         || grep { $_ eq $filter->{type} } @{$q->{types}});
  } @$all;

  # RFC 9425 S4.4: sort by name or used; ids break ties so paging is stable
  my %keys;
  @filtered = sort {
    my $res = 0;
    for my $cmp (@{$args->{sort} || []}) {
      $res = $cmp->{property} eq 'used'
        ? ($a->{used} // 0) <=> ($b->{used} // 0)
        : JMAP::Collation::compare($cmp->{collation}, $a->{name}, $b->{name}, \%keys);
      $res = -$res if defined $cmp->{isAscending} && !$cmp->{isAscending};
      last if $res;
    }
    $res || $a->{id} cmp $b->{id};
  } @filtered;
  return [ map { $_->{id} } @filtered ];
}

sub _quota_bad_sort {
  my ($args) = @_;
  for my $cmp (@{$args->{sort} || []}) {
    return $cmp unless ref $cmp eq 'HASH' && ($cmp->{property} // '') =~ /^(?:name|used)$/;
  }
  return undef;
}

sub api_Quota_query {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  return ['error', {type => 'invalidArguments', arguments => ['position']}]
    if ($args->{position} // 0) < 0;
  if (my $bad = _quota_bad_sort($args)) {
    return ['error', {type => 'unsupportedSort', sort => $bad}];
  }

  my @all   = _get_all_quotas($Self, $user);
  my $state = _quota_remember($Self, \@all);
  my $ids   = _quota_query_ids($Self, $args, \@all);
  $Self->{db}->save_query('Quota', { filter => $args->{filter}, sort => $args->{sort} }, $state, $ids);

  my ($start, $end) = $Self->_apply_window([ map { { id => $_ } } @$ids ], $args, sub { $_[0]{id} });
  return ['error', {type => 'anchorNotFound'}] unless defined $start;

  return ['Quota/query', {
    accountId           => $accountid,
    queryState          => $state,
    canCalculateChanges => JSON::true,
    position            => $start + 0,
    total               => scalar(@$ids) + 0,
    ids                 => [ @$ids[$start .. $end] ],
  }];
}

sub api_Quota_queryChanges {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  if (my $bad = _quota_bad_sort($args)) {
    return ['error', {type => 'unsupportedSort', sort => $bad}];
  }

  my @all    = _get_all_quotas($Self, $user);
  my $state  = _quota_remember($Self, \@all);
  my $since  = $args->{sinceQueryState} // '';
  my $params = { filter => $args->{filter}, sort => $args->{sort} };
  my $old_ids = $Self->{db}->load_query('Quota', $params, $since);
  my $old     = $Self->{db}->load_query('QuotaState', {}, $since);
  return ['error', {type => 'cannotCalculateChanges', newQueryState => $state}]
    unless $old_ids && $old;

  my $new_ids = _quota_query_ids($Self, $args, \@all);
  $Self->{db}->save_query('Quota', $params, $state, $new_ids);

  # RFC 8620 S5.6: sorting on a mutable property (used) means every quota
  # whose value changed is removed and re-added at its new position.
  my $now = _quota_snapshot(\@all);
  my %changed;
  if (grep { ($_->{property} // '') eq 'used' } @{$args->{sort} || []}) {
    %changed = map { $_ => 1 } grep { ($old->{$_} // '') ne $now->{$_} } keys %$now;
  }
  my %old_set = map { $_ => 1 } @$old_ids;
  my %new_set = map { $_ => 1 } @$new_ids;
  my @removed = ((grep { !$new_set{$_} } @$old_ids), (grep { $changed{$_} && $old_set{$_} } @$new_ids));
  my @added;
  for my $i (0 .. $#$new_ids) {
    my $id = $new_ids->[$i];
    push @added, { id => $id, index => $i } if !$old_set{$id} || $changed{$id};
  }
  if (defined $args->{upToId}) {
    my ($cut) = grep { $new_ids->[$_] eq $args->{upToId} } 0 .. $#$new_ids;
    @added = grep { $_->{index} <= $cut } @added if defined $cut;
  }
  return ['error', {type => 'tooManyChanges'}]
    if $args->{maxChanges} && @removed + @added > $args->{maxChanges};

  return ['Quota/queryChanges', {
    accountId     => $accountid,
    oldQueryState => $since,
    newQueryState => $state,
    removed       => \@removed,
    added         => \@added,
    total         => scalar(@$new_ids),
  }];
}

1;
