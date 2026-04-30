package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;

my $json = JSON::XS->new->utf8->canonical();

sub _is_origin {
  my ($organizer, $user_email) = @_;
  return JSON::true unless defined $organizer;
  my $org_email = lc($organizer =~ s{^mailto:}{}ri);
  return (lc($user_email // '') eq $org_email) ? JSON::true : JSON::false;
}

sub getCalendarPreferences {
  return ['calendarPreferences', {
    autoAddCalendarId         => '',
    autoAddInvitations        => JSON::false,
    autoAddGroupId            => JSON::null,
    autoRSVPGroupId           => JSON::null,
    autoRSVP                  => JSON::false,
    autoUpdate                => JSON::false,
    birthdaysAreVisible       => JSON::false,
    defaultAlerts             => {},
    defaultAllDayAlerts       => {},
    defaultCalendarId         => '',
    firstDayOfWeek            => 1,
    markReadAndFileAutoAdd    => JSON::false,
    markReadAndFileAutoUpdate => JSON::false,
    onlyAutoAddIfInGroup      => JSON::false,
    onlyAutoRSVPIfInGroup     => JSON::false,
    showWeekNumbers           => JSON::false,
    timeZone                  => JSON::null,
    useTimeZones              => JSON::false,
  }];
}

sub api_Calendar_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateCalendar}";

  my $data = $Self->{db}->dget('jcalendars', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_->{jcalendarid} => 1 } @$data;
  }

  my @list;

  foreach my $item (@$data) {
    next unless delete $want{$item->{jcalendarid}};

    my %rec = (
      id                     => "$item->{jcalendarid}",
      name                   => "$item->{name}",
      color                  => "$item->{color}",
      sortOrder              => $item->{sortOrder}  || 0,
      isDefault              => $item->{isDefault}  ? $JSON::true : $JSON::false,
      isSubscribed           => $JSON::true,
      includeInAvailability  => $item->{includeInAvailability} || 'all',
      isVisible              => $item->{isVisible}  ? $JSON::true : $JSON::false,
      myRights => {
        mayReadFreeBusy  => $item->{mayReadFreeBusy}  ? $JSON::true : $JSON::false,
        mayReadItems     => $item->{mayReadItems}     ? $JSON::true : $JSON::false,
        mayWriteAll      => $item->{mayAddItems}      ? $JSON::true : $JSON::false,
        mayWriteOwn      => $item->{mayAddItems}      ? $JSON::true : $JSON::false,
        mayUpdatePrivate => $item->{mayModifyItems}   ? $JSON::true : $JSON::false,
        mayRSVP          => $JSON::false,
        mayAdmin         => $item->{mayDelete}        ? $JSON::true : $JSON::false,
        mayDelete        => $item->{mayDelete}        ? $JSON::true : $JSON::false,
      },
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }

  $Self->commit();

  my %missingids = %want;

  return ['Calendar/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Calendar_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateCalendar}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $sinceState = $args->{sinceState};

  my $data = $Self->{db}->dget('jcalendars', {}, 'jcalendarid,jmodseq,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @changed = grep { $_->{jmodseq} > $sinceState } @$data;
  my ($created, $updated, $destroyed) = $Self->_classify_changes(\@changed, $sinceState, 'jcalendarid');

  my @res = (['Calendar/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    created => [map { "$_" } @$created],
    updated => [map { "$_" } @$updated],
    destroyed => [map { "$_" } @$destroyed],
    hasMoreChanges => JSON::false,
  }]);

  return @res;
}

sub api_Calendar_set {
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

  $Self->{db}->sync_calendars();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateCalendar}";
  $Self->commit();

  ($created, $notCreated) = $Self->{db}->create_calendars($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Calendar_get');
  ($updated, $notUpdated) = $Self->{db}->update_calendars($update, sub { $Self->idmap(shift) });

  my $onDestroyRemoveEvents = $args->{onDestroyRemoveEvents} ? 1 : 0;
  my (@safe_destroy, %notDestroyed_pre);
  for my $jcalendarid (@$destroy) {
    $Self->begin();
    my $has_events = $Self->{db}->dcount('jevents', { jcalendarid => $jcalendarid, active => 1 });
    my $event_uids = $has_events
      ? $Self->{db}->dgetcol('jevents', { jcalendarid => $jcalendarid, active => 1 }, 'eventuid')
      : [];
    $Self->commit();
    if ($has_events && !$onDestroyRemoveEvents) {
      $notDestroyed_pre{$jcalendarid} = { type => 'calendarHasEvent' };
    } else {
      $Self->{db}->destroy_calendar_events($event_uids) if @$event_uids;
      push @safe_destroy, $jcalendarid;
    }
  }

  ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendars(\@safe_destroy);
  for my $id (keys %notDestroyed_pre) {
    $notDestroyed->{$id} = $notDestroyed_pre{$id};
  }

  # XXX - cheap dumb racy version
  $Self->{db}->sync_calendars();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateCalendar}";
  $Self->commit();

  my @res;
  push @res, ['Calendar/set', {
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

sub _event_match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  # XXX - condition handling code
  if ($condition->{inCalendars}) {
    my $match = 0;
    foreach my $id (@{$condition->{inCalendars}}) {
      next unless $item->{jcalendarid} eq $id;
      $match = 1;
    }
    return 0 unless $match;
  }

  # Date-range filter: events must overlap [after, before).
  # We only filter events that have start in payload (non-recurring check).
  # Recurring events always pass — expansion is the client's job per spec.
  if ($condition->{after} || $condition->{before}) {
    my $payload = $Self->{db}->read_jevent_payload($item->{eventuid}) // {};
    my $start = $payload->{start} // '';
    my $duration = $payload->{duration} // 'PT0S';
    my $is_recurring = $payload->{recurrenceRules} || $payload->{recurrenceRule};
    unless ($is_recurring) {
      if ($condition->{after} && $start lt $condition->{after}) {
        # simple string compare works for ISO 8601 datetimes
        return 0;
      }
      if ($condition->{before} && $start ge $condition->{before}) {
        return 0;
      }
    }
  }

  return 1;
}

sub _event_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  my @res;
  foreach my $item (@$data) {
    next unless $Self->_event_match($item, $filter, $storage);
    push @res, $item;
  }
  return \@res;
}

sub api_CalendarEvent_query {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateCalendarEvent}";

  my $data = $Self->{db}->dget('jevents', { active => 1 }, 'eventuid,jcalendarid');

  $data = $Self->_event_filter($data, $args->{filter}, {}) if $args->{filter};

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['position']}])
    if ($args->{position} // 0) < 0;

  my ($start, $end) = $Self->_apply_window($data, $args, sub { $_[0]{eventuid} });
  return $Self->_transError(['error', {type => 'anchorNotFound'}]) unless defined $start;

  my @result = map { $data->[$_]{eventuid} } $start..$end;

  $Self->commit();

  my @res;
  push @res, ['CalendarEvent/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub _expand_occurrence {
  my ($master, $recurrence_id) = @_;

  my $overrides = $master->{recurrenceOverrides} || {};

  # Explicitly excluded occurrence
  return undef if exists $overrides->{$recurrence_id} && !defined $overrides->{$recurrence_id};

  my %item  = %$master;
  my $patch = $overrides->{$recurrence_id} || {};
  $item{$_} = $patch->{$_} for keys %$patch;

  # start: override's value if it was moved, otherwise the scheduled recurrenceId
  $item{start}       = exists $patch->{start} ? $patch->{start} : $recurrence_id;
  $item{recurrenceId} = $recurrence_id;

  # master-only properties are not valid on expanded occurrences (RFC 8984 §4.3)
  delete $item{$_} for qw(recurrenceRules recurrenceOverrides excludedRecurrenceRules);

  return \%item;
}

sub api_CalendarEvent_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateCalendarEvent}";

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['ids']}])
    unless $args->{ids};

  my %seenids;
  my %missingids;
  my @list;
  foreach my $eventuid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$eventuid};
    $seenids{$eventuid} = 1;

    # Occurrence ID: masterUid/recurrenceId
    if ($eventuid =~ m{^([^/]+)/(.+)$}) {
      my ($master_uid, $recurrence_id) = ($1, $2);

      my $data = $Self->{db}->dgetone('jevents', { eventuid => $master_uid }, 'jcalendarid');
      unless ($data) {
        $missingids{$eventuid} = 1;
        next;
      }

      my $master = $Self->{db}->read_jevent_payload($master_uid);
      unless ($master) {
        $missingids{$eventuid} = 1;
        next;
      }

      my $item = _expand_occurrence($master, $recurrence_id);
      unless ($item) {
        $missingids{$eventuid} = 1;  # excluded occurrence
        next;
      }

      my $organizer = $item->{organizerCalendarAddress};
      foreach my $key (keys %$item) {
        delete $item->{$key} unless _prop_wanted($args, $key);
      }
      $item->{id}          = $eventuid;
      $item->{calendarIds} = { "$data->{jcalendarid}" => JSON::true } if _prop_wanted($args, 'calendarIds');
      $item->{isOrigin}    = _is_origin($organizer, $user->{email})   if _prop_wanted($args, 'isOrigin');
      push @list, $item;
      next;
    }

    # Master event
    my $data = $Self->{db}->dgetone('jevents', { eventuid => $eventuid }, 'jcalendarid');
    unless ($data) {
      $missingids{$eventuid} = 1;
      next;
    }

    my $item = $Self->{db}->read_jevent_payload($eventuid);
    unless ($item) {
      $missingids{$eventuid} = 1;
      next;
    }

    my $organizer = $item->{organizerCalendarAddress};
    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id}          = $eventuid;
    $item->{calendarIds} = { "$data->{jcalendarid}" => JSON::true } if _prop_wanted($args, "calendarIds");
    $item->{isOrigin}    = _is_origin($organizer, $user->{email})   if _prop_wanted($args, 'isOrigin');

    push @list, $item;
  }

  $Self->commit();

  return ['CalendarEvent/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_CalendarEvent_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateCalendarEvent}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;

  my $data = $Self->{db}->dget('jevents', { jmodseq => ['>', $args->{sinceState}] }, 'eventuid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'eventuid');

  my @res;
  push @res, ['CalendarEvent/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => [map { "$_" } @$created],
    updated => [map { "$_" } @$updated],
    destroyed => [map { "$_" } @$destroyed],
    hasMoreChanges => JSON::false,
  }];

  return @res;
}

sub api_CalendarEvent_queryChanges {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateCalendarEvent}";
  my $sinceQueryState = $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    unless $sinceQueryState;
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $sinceQueryState <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jevents', { active => 1 }, 'eventuid,jmodseq');
  my $total = scalar @$data;

  my %idx;
  my $i = 0;
  $idx{$_->{eventuid}} = $i++ for @$data;

  my $changed = $Self->{db}->dget('jevents', { jmodseq => ['>', $sinceQueryState] }, 'eventuid,active');

  $Self->commit();

  my @added;
  my @destroyed;
  for my $row (@$changed) {
    push @destroyed, "$row->{eventuid}";
    if ($row->{active} && exists $idx{$row->{eventuid}}) {
      push @added, { id => "$row->{eventuid}", index => $idx{$row->{eventuid}} };
    }
  }

  return ['CalendarEvent/queryChanges', {
    accountId     => $accountid,
    filter        => $args->{filter},
    sort          => $args->{sort},
    oldQueryState => "$sinceQueryState",
    newQueryState => $newQueryState,
    total         => $total,
    removed       => \@destroyed,
    added         => \@added,
  }];
}

sub api_CalendarEvent_copy {
  my $Self = shift;
  my $args = shift;
  my $accountid = $Self->{db}->accountid();
  return ['error', { type => 'notImplemented' }];
}

sub api_CalendarEvent_parse {
  my $Self = shift;
  my $args = shift;
  return ['error', { type => 'notImplemented' }];
}

sub api_CalendarEvent_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
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

  $Self->{db}->sync_calendars();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateCalendarEvent}";
  $Self->commit();

  ($created, $notCreated) = $Self->{db}->create_calendar_events($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_CalendarEvent_get');
  ($updated, $notUpdated) = $Self->{db}->update_calendar_events($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendar_events($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_calendars();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateCalendarEvent}";
  $Self->commit();

  my @res;
  push @res, ['CalendarEvent/set', {
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

sub api_ParticipantIdentity_get {
  my $Self = shift;
  my $args = shift;
  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my $email = $user->{email} // '';
  my @identities;
  my @notFound;

  if ($args->{ids}) {
    for my $id (@{$args->{ids}}) {
      if ($email && $id eq 'id1') {
        push @identities, { id => 'id1', name => '', sendTo => { imip => "mailto:$email" } };
      } else {
        push @notFound, "$id";
      }
    }
  } elsif ($email) {
    push @identities, { id => 'id1', name => '', sendTo => { imip => "mailto:$email" } };
  }

  return ['ParticipantIdentity/get', {
    accountId => $accountid,
    state     => "$user->{jhighestmodseq}",
    list      => \@identities,
    notFound  => \@notFound,
  }];
}

sub api_ParticipantIdentity_changes {
  my $Self = shift;
  my $args = shift;
  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();
  my $state = "$user->{jhighestmodseq}";
  return ['ParticipantIdentity/changes', {
    accountId      => $accountid,
    oldState       => $args->{sinceState} // $state,
    newState       => $state,
    created        => [],
    updated        => [],
    destroyed      => [],
    hasMoreChanges => JSON::false,
  }];
}

sub api_ParticipantIdentity_set {
  my $Self = shift;
  my $args = shift;
  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();
  my $state = "$user->{jhighestmodseq}";
  my %notCreated = map { $_ => { type => 'notImplemented' } } keys %{$args->{create} || {}};
  return ['ParticipantIdentity/set', {
    accountId    => $accountid,
    oldState     => $state,
    newState     => $state,
    created      => undef,
    notCreated   => _nullempty(\%notCreated),
    updated      => undef,
    notUpdated   => undef,
    destroyed    => undef,
    notDestroyed => undef,
  }];
}

1;
