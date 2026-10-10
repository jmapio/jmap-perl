package JMAP::API;
use strict;
use warnings;
use Digest::SHA qw(sha1_hex);
use JSON;

use JMAP::Capabilities qw(imap_account_capabilities);

# RFC 9670 principals, for an IMAP-backed account. The proxy fronts exactly one
# user per account, so there is exactly one Principal, and its id is the
# currentUserPrincipalId the session advertises.
our $PRINCIPAL_ID = 'me';

sub _principal {
  my ($Self, $user, $accountid) = @_;

  my $email = $user->{email};
  $email = undef unless defined $email and length $email;

  my $name = $user->{displayname};
  $name = $email      unless defined $name and length $name;
  $name = $accountid  unless defined $name and length $name;

  my $iserver = eval { $Self->{db}->dgetone('iserver') } || {};

  return {
    id           => $PRINCIPAL_ID,
    type         => 'individual',
    name         => "$name",
    description  => undef,
    email        => $email,
    timeZone     => undef,
    # draft-ietf-jmap-calendars S2.1. Only one Principal exists here, so it is
    # never a share target.
    capabilities => $iserver->{caldavURL} ? {
      'urn:ietf:params:jmap:calendars' => {
        accountId          => "$accountid",
        mayGetAvailability => JSON::true,
        mayShareWith       => JSON::false,
        calendarAddress    => $email ? "mailto:$email" : undef,
      },
    } : {},
    accounts     => {
      "$accountid" => {
        name                => "$name",
        isPersonal          => JSON::true,
        isReadOnly          => JSON::false,
        accountCapabilities => imap_account_capabilities($iserver),
      },
    },
  };
}

sub _principal_state {
  my ($principal) = @_;
  return sha1_hex(join("\0", map { $principal->{$_} // '' } qw(id type name email)));
}

# Remember every state the principal is seen in (for the jqueries cache's
# hour), so /changes can tell a real earlier state from a stranger's.
sub _principal_remember {
  my ($Self, $principal) = @_;
  my $state = _principal_state($principal);
  $Self->{db}->save_query('PrincipalState', {}, $state, [$principal->{id}]);
  return $state;
}

sub api_Principal_get {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $principal = $Self->_principal($user, $accountid);
  $Self->commit();

  my (@list, @not_found);
  if ($args->{ids}) {
    for my $id (map { $Self->idmap($_) } @{$args->{ids}}) {
      $id eq $PRINCIPAL_ID ? push(@list, $principal) : push(@not_found, $id);
    }
  } else {
    @list = ($principal);
  }

  if ($args->{properties}) {
    my %want = (id => 1, map { $_ => 1 } @{$args->{properties}});
    @list = map { my $p = $_; +{ map { exists $p->{$_} ? ($_ => $p->{$_}) : () } keys %want } } @list;
  }

  return ['Principal/get', {
    accountId => $accountid,
    state     => _principal_remember($Self, $principal),
    list      => \@list,
    notFound  => \@not_found,
  }];
}

sub _principal_matches {
  my ($principal, $filter) = @_;
  return 1 unless $filter and %$filter;

  if (my $ids = $filter->{accountIds}) {
    return 0 unless grep { exists $principal->{accounts}{$_} } @$ids;
  }
  for my $prop (qw(type timeZone)) {
    next unless defined $filter->{$prop};
    return 0 unless defined $principal->{$prop} and $principal->{$prop} eq $filter->{$prop};
  }
  for my $prop (qw(name email)) {
    next unless defined $filter->{$prop};
    return 0 unless defined $principal->{$prop}
                and index($principal->{$prop}, $filter->{$prop}) >= 0;
  }
  if (defined $filter->{text}) {
    return 0 unless grep { defined $_ and index($_, $filter->{text}) >= 0 }
                      @{$principal}{qw(name email description)};
  }
  return 1;
}

sub api_Principal_query {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $principal = $Self->_principal($user, $accountid);
  $Self->commit();

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['position']}])
    if ($args->{position} // 0) < 0;

  my @matched = _principal_matches($principal, $args->{filter}) ? ($principal) : ();
  my $state = _principal_remember($Self, $principal);
  $Self->{db}->save_query('Principal', { filter => $args->{filter}, sort => $args->{sort} },
                          $state, [ map { $_->{id} } @matched ]);

  my ($start, $end) = $Self->_apply_window(\@matched, $args, sub { $_[0]{id} });
  return $Self->_transError(['error', {type => 'anchorNotFound'}]) unless defined $start;

  return ['Principal/query', {
    accountId           => $accountid,
    queryState          => $state,
    canCalculateChanges => JSON::true,
    position            => $start + 0,
    total               => scalar(@matched) + 0,
    ids                 => [map { $matched[$_]{id} } $start .. $end],
  }];
}

# The one principal is derived from the account; any earlier state of ours
# that we remember means it has been updated since.
sub api_Principal_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $principal = $Self->_principal($user, $accountid);
  $Self->commit();
  my $state = _principal_remember($Self, $principal);
  my $since = $args->{sinceState} // '';
  return ['error', {type => 'cannotCalculateChanges', newState => $state}]
    unless $since eq $state || $Self->{db}->load_query('PrincipalState', {}, $since);

  return ['Principal/changes', {
    accountId      => $accountid,
    oldState       => $since,
    newState       => $state,
    hasMoreChanges => JSON::false,
    created        => [],
    updated        => $since eq $state ? [] : [$principal->{id}],
    destroyed      => [],
  }];
}

sub api_Principal_queryChanges {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $principal = $Self->_principal($user, $accountid);
  $Self->commit();
  my $state  = _principal_remember($Self, $principal);
  my $since  = $args->{sinceQueryState} // '';
  my $params = { filter => $args->{filter}, sort => $args->{sort} };
  my $old    = $Self->{db}->load_query('Principal', $params, $since);
  return ['error', {type => 'cannotCalculateChanges', newQueryState => $state}] unless $old;

  my @new = _principal_matches($principal, $args->{filter}) ? ($principal->{id}) : ();
  $Self->{db}->save_query('Principal', $params, $state, \@new);

  # RFC 8620 S5.6: name and email are mutable, so a principal that changed
  # is removed and added back.
  my $changed = $since ne $state;
  my %old = map { $_ => 1 } @$old;
  my %new = map { $_ => 1 } @new;
  return ['Principal/queryChanges', {
    accountId     => $accountid,
    oldQueryState => $since,
    newQueryState => $state,
    removed       => [ grep { !$new{$_} || $changed } @$old ],
    added         => [ map { { id => $new[$_], index => $_ } }
                       grep { !$old{$new[$_]} || $changed } 0 .. $#new ],
    total         => scalar(@new),
  }];
}

# RFC 9670 S2.3: principals come from the backend account, not from clients.
sub api_Principal_set {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $principal = $Self->_principal($user, $accountid);
  my $state = _principal_state($principal);
  $Self->commit();

  return $Self->_transError(['error', {type => 'stateMismatch', oldState => $state, newState => $state}])
    if defined $args->{ifInState} and $args->{ifInState} ne $state;

  return ['Principal/set', {
    accountId    => $accountid,
    oldState     => $state,
    newState     => $state,
    created      => undef,
    notCreated   => { map { $_ => { type => 'forbidden' } } keys %{ $args->{create}  || {} } },
    updated      => undef,
    notUpdated   => { map { $_ => { type => 'forbidden' } } keys %{ $args->{update}  || {} } },
    destroyed    => undef,
    notDestroyed => { map { $_ => { type => 'forbidden' } } @{ $args->{destroy} || [] } },
  }];
}

1;
