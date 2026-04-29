package JMAP::API;
use strict;
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
  return sha1_hex(join(',', map { "$_->{id}=$_->{used}/$_->{hardLimit}" }
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
    used         => $raw->{used}  * $scale,
    hardLimit    => $raw->{limit} * $scale,
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
    state     => _quota_state(\@all),
    list      => \@list,
    notFound  => \@not_found,
  }];
}

sub api_Quota_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my @all  = _get_all_quotas($Self, $user);
  my $state = _quota_state(\@all);
  return ['error', {type => 'cannotCalculateChanges', newState => $state}];
}

sub api_Quota_query {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my @all = _get_all_quotas($Self, $user);

  my $filter = $args->{filter} || {};
  my @filtered = grep {
    my $q = $_;
    (!defined $filter->{name}         || index($q->{name}, $filter->{name}) >= 0) &&
    (!defined $filter->{resourceType} || $q->{resourceType} eq $filter->{resourceType}) &&
    (!defined $filter->{type}         || grep { $_ eq $filter->{type} } @{$q->{types}});
  } @all;

  return ['error', {type => 'invalidArguments', arguments => ['position']}]
    if ($args->{position} // 0) < 0;

  my ($start, $end) = $Self->_apply_window(\@filtered, $args, sub { $_[0]{id} });
  return ['error', {type => 'anchorNotFound'}] unless defined $start;

  my @ids = map { $filtered[$_]{id} } $start .. $end;

  return ['Quota/query', {
    accountId           => $accountid,
    queryState          => _quota_state(\@all),
    canCalculateChanges => JSON::false,
    position            => $start + 0,
    total               => scalar(@filtered) + 0,
    ids                 => \@ids,
  }];
}

sub api_Quota_queryChanges {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my @all   = _get_all_quotas($Self, $user);
  my $state = _quota_state(\@all);
  return ['error', {type => 'cannotCalculateChanges', newQueryState => $state}];
}

1;
