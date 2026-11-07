package JMAP::API;
use strict;
use JMAP::Collation;
use JMAP::QueryChanges;
use JMAP::EventId;
use warnings;

use JSON::XS;
use JSON;
use DateTime;
use DateTime::TimeZone;
use Text::JSCalendar;

my $json = JSON::XS->new->utf8->canonical();

# Parse a JSCalendar floating datetime string into a DateTime in the given tz.
# Format: "YYYY-MM-DDTHH:MM:SS" or "YYYY-MM-DD" (all-day).
sub _parse_jscal_dt {
  my ($str, $tz) = @_;
  $str //= '';
  if ($str =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
    return eval { DateTime->new(year=>$1,month=>$2,day=>$3,hour=>$4,minute=>$5,second=>$6,time_zone=>$tz) };
  }
  if ($str =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
    return eval { DateTime->new(year=>$1,month=>$2,day=>$3,time_zone=>$tz) };
  }
  return undef;
}

# Compute utcStart string from a JSCalendar start + timeZone.
# Returns undef for all-day events (no T in start).
sub _utc_start {
  my ($start, $tz) = @_;
  return undef unless defined $start && $start =~ /T/;
  my $dt = _parse_jscal_dt($start, $tz // 'UTC');
  return undef unless $dt;
  $dt->set_time_zone('UTC');
  return $dt->strftime('%Y-%m-%dT%H:%M:%SZ');
}

# Add an ISO 8601 duration string (PnDTnHnMnS / PnW) to a DateTime, return new DateTime.
sub _dt_add_duration {
  my ($dt, $dur) = @_;
  return undef unless $dur && $dur =~ /^P/;
  my ($w,$d,$h,$m,$s) = (0,0,0,0,0);
  (my $rest = $dur) =~ s/^P//;
  $rest =~ s/^(\d+)W// and $w = $1;
  $rest =~ s/^(\d+)D// and $d = $1;
  $rest =~ s/^T//;
  $rest =~ s/^(\d+)H// and $h = $1;
  $rest =~ s/^(\d+)M// and $m = $1;
  $rest =~ s/^(\d+(?:\.\d+)?)S// and $s = int($1);
  return eval { $dt->clone->add(weeks=>$w, days=>$d, hours=>$h, minutes=>$m, seconds=>$s) };
}

# Returns true only when the property is explicitly listed in $args->{properties}.
# Unlike _prop_wanted, does NOT return true when properties is omitted (i.e. "all").
# Used for computed properties like utcStart/utcEnd that are never returned by default.
sub _prop_explicitly_wanted {
  my ($args, $prop) = @_;
  return 0 unless $args->{properties};
  return grep { $_ eq $prop } @{$args->{properties}};
}

# Set server-computed properties on a calendar event item hash.
# utcStart and utcEnd, when asked for, from the event's start, timeZone and
# duration. Run it before the unrequested properties are deleted. A floating
# event is read in the request's timeZone (draft-ietf-jmap-calendars S5.8,
# "default Etc/UTC"); duration defaults to PT0S (JSCalendar).
sub _calendar_event_computed_props {
  my ($item, $args) = @_;
  my %out;
  my $want_start = _prop_explicitly_wanted($args, 'utcStart');
  my $want_end   = _prop_explicitly_wanted($args, 'utcEnd');
  return () unless $want_start || $want_end;
  my $tz = $item->{timeZone} // $args->{timeZone} // 'Etc/UTC';
  my $us = _utc_start($item->{start}, $tz);
  $out{utcStart} = $us if $want_start;
  if ($want_end) {
    my $dt  = $us ? _parse_jscal_dt(substr($us, 0, 19), 'UTC') : undef;
    my $end = $dt ? _dt_add_duration($dt, $item->{duration} // 'PT0S') : undef;
    $out{utcEnd} = $end ? $end->strftime('%Y-%m-%dT%H:%M:%SZ') : undef;
  }
  return %out;
}

# draft-ietf-jmap-calendars S5.8: with recurrenceOverridesBefore/After, only
# the overrides whose recurrence id, "translated into UTC", is before (or on
# or after) the given time are returned.
sub _window_overrides {
  my ($item, $args) = @_;
  my ($after, $before) = @$args{qw(recurrenceOverridesAfter recurrenceOverridesBefore)};
  return unless (defined $after || defined $before) && ref $item->{recurrenceOverrides} eq 'HASH';
  my $tz = $item->{timeZone} // $args->{timeZone} // 'Etc/UTC';
  for my $rid (keys %{$item->{recurrenceOverrides}}) {
    my $u = _utc_start($rid =~ /T/ ? $rid : "${rid}T00:00:00", $tz) // next;
    delete $item->{recurrenceOverrides}{$rid}
      if (defined $after && $u lt $after) || (defined $before && $u ge $before);
  }
}

# The occurrences of a recurring event to report for a query window
# [after, before): {id, rid, start} for each.  Text::JSCalendar expands the
# rule (every part of it, RDATE-style additions, exclusions; bounded); an
# occurrence counts by where it actually starts, so one moved out of the
# window is left out and one moved into it from outside is added.
sub _expand_event_occurrences {
  my ($Self, $row, $master, $after_str, $before_str) = @_;
  return () unless defined $master->{start};

  # after/before may carry a trailing Z; compared as local times, as the
  # string-compare filter does
  (my $after_cmp  = $after_str  // '') =~ s/Z$//;
  (my $before_cmp = $before_str // '') =~ s/Z$//;

  my $overrides = $master->{recurrenceOverrides} // {};
  my $item = sub {
    my $rid = shift;
    my $patch = $overrides->{$rid};
    my $actual_start = (ref $patch eq 'HASH' && defined $patch->{start}) ? $patch->{start} : $rid;
    return () if length $after_cmp  && $actual_start lt $after_cmp;
    return () if length $before_cmp && $actual_start ge $before_cmp;
    return { id => JMAP::EventId::instance_id($row->{eventuid}, $rid),
             rid => $rid, start => $actual_start };
  };

  my @rids = eval { Text::JSCalendar->occurrences($master,
    (length $after_cmp ? (after => $after_cmp) : ()),
    (length $before_cmp ? (before => $before_cmp) : ())) };
  warn "CalendarEvent/query: $row->{eventuid}: cannot expand: $@" if $@;
  my %seen = map { $_ => 1 } @rids;
  my @items = map { $item->($_) } @rids;

  # moved overrides whose natural occurrence is outside the window
  for my $rid (sort keys %$overrides) {
    next if $seen{$rid};
    my $patch = $overrides->{$rid};
    next unless ref $patch eq 'HASH' && !$patch->{excluded};
    push @items, $item->($rid);
  }
  return @items;
}

# CalendarEvent ids are not the UIDs events are stored under (JMAP::EventId).
# Returns a sub turning an id into ($uid) for an event or ($uid, $rid) for one
# instance of it, and () when no id we hand out looks like that.  A hashed id
# takes every UID, read once on first use, so call it inside the transaction.
sub _event_id_resolver {
  my $Self = shift;
  my $hashed;
  return sub {
    my $id = shift;
    my ($event, $rid) = JMAP::EventId::parse_id($id);
    return () unless defined $event;
    my $uid = $event;
    if (JMAP::EventId::is_hashed($event)) {
      $uid = $hashed->{$event} //= $Self->{db}->dgetfield('jevents', { jeventhash => $event }, 'eventuid');
      return () unless defined $uid;
    }
    # Only the id we would hand out for this event: not its raw UID, nor the
    # "UID/recurrenceId" this proxy used to answer with.
    return () unless (JMAP::EventId::event_id($uid, $rid) // '') eq $id;
    return defined $rid ? ($uid, $rid) : ($uid);
  };
}

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
      name                   => _db_text($item->{name} // ''),
      color                  => "$item->{color}",
      sortOrder              => $item->{sortOrder}  || 0,
      isDefault              => $item->{isDefault}  ? $JSON::true : $JSON::false,
      isSubscribed           => $item->{isVisible} ? $JSON::true : $JSON::false,
      includeInAvailability  => $item->{includeInAvailability} || 'all',
      isVisible              => $item->{isVisible}  ? $JSON::true : $JSON::false,
      description            => _db_text($item->{description}) // JSON::null,
      timeZone               => $item->{timeZone}    // JSON::null,
      defaultAlertsWithTime    => $item->{defaultAlertsWithTime}
                                  ? $json->decode($item->{defaultAlertsWithTime}) : JSON::null,
      defaultAlertsWithoutTime => $item->{defaultAlertsWithoutTime}
                                  ? $json->decode($item->{defaultAlertsWithoutTime}) : JSON::null,
      myRights => {
        mayReadFreeBusy  => $item->{mayReadFreeBusy}  ? $JSON::true : $JSON::false,
        mayReadItems     => $item->{mayReadItems}     ? $JSON::true : $JSON::false,
        mayWriteAll      => $item->{mayAddItems}      ? $JSON::true : $JSON::false,
        mayWriteOwn      => ($item->{mayAddItems} || $item->{mayModifyItems}) ? $JSON::true : $JSON::false,
        mayUpdatePrivate => $item->{mayModifyItems}   ? $JSON::true : $JSON::false,
        mayRSVP          => $JSON::false,
        mayShare         => $JSON::false,
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

  my $data = $Self->{db}->dget('jcalendars', { jmodseq => ['>', $sinceState] }, 'jcalendarid,jmodseq,active,jcreated');
  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless defined $data;

  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $sinceState, 'jcalendarid');

  my @res = (['Calendar/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    created => [map { "$_" } @$created],
    updated => [map { "$_" } @$updated],
    destroyed => [map { "$_" } @$destroyed],
    hasMoreChanges => $partial ? JSON::true : JSON::false,
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

  $create = { %$create };
  my ($badCreate) = $Self->_collection_precheck($create, {}, 'api_Calendar_get');
  ($created, $notCreated) = $Self->{db}->create_calendars($create);
  $notCreated = { %{$notCreated || {}}, %$badCreate } if %$badCreate;
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  # RFC 8620 S5.3: created holds every property the client did not send --
  # the server-set ones and those the server defaulted
  if (%$created) {
    my $res = $Self->api_Calendar_get({ ids => [map { $_->{id} } values %$created] });
    my %got = map { $_->{id} => $_ } @{ $res->[1]{list} || [] };
    for my $cid (keys %$created) {
      my $rec = $got{ $created->{$cid}{id} } or next;
      for my $prop (keys %$rec) {
        $created->{$cid}{$prop} = $rec->{$prop} unless exists $create->{$cid}{$prop};
      }
    }
  }
  my $patchInvalid = $Self->_resolve_patch($update, 'api_Calendar_get');
  # after _resolve_patch, so a myRights/... patch is checked as a whole
  my (undef, $badUpdate) = $Self->_collection_precheck({}, $update, 'api_Calendar_get');
  ($updated, $notUpdated) = $Self->{db}->update_calendars($update, sub { $Self->idmap(shift) });
  $notUpdated = { %{$notUpdated || {}}, %$badUpdate } if %$badUpdate;
  $notUpdated = { %{$notUpdated || {}}, %$patchInvalid } if %$patchInvalid;   # RFC 8620 S5.3

  my $onDestroyRemoveEvents = $args->{onDestroyRemoveEvents} ? 1 : 0;
  my (@safe_destroy, %notDestroyed_pre);
  for my $jcalendarid (@$destroy) {
    $Self->begin();
    my $has_events = grep { $_ eq $jcalendarid } map { JMAP::DB::event_calendar_ids($_) }
      @{ $Self->{db}->dget('jevents', { active => 1 }, 'jcalendarid,jcalendarids') };
    $Self->commit();
    if ($has_events && !$onDestroyRemoveEvents) {
      $notDestroyed_pre{$jcalendarid} = { type => 'calendarHasEvent' };
    } else {
      # Its events are not destroyed one by one first: had the calendar's
      # DELETE then failed, they would be gone and the calendar left.  A
      # collection's DELETE removes its members (RFC 4918 S9.6.1), and the
      # sync after it destroys them here.
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

  # an event is in every calendar of its calendarIds
  if ($condition->{inCalendar}) {
    return 0 unless grep { $_ eq $condition->{inCalendar} } JMAP::DB::event_calendar_ids($item);
  }
  if ($condition->{inCalendars}) {
    my %cal_set = map { $_ => 1 } @{$condition->{inCalendars}};
    return 0 unless grep { $cal_set{$_} } JMAP::DB::event_calendar_ids($item);
  }

  if (defined $condition->{uid}) {
    return 0 unless $item->{eventuid} eq $condition->{uid};
  }

  my $needs_payload = grep { defined $condition->{$_} }
      qw(after before text title description location owner attendee);

  if ($needs_payload) {
    my $uid     = $item->{eventuid};
    my $payload = $storage->{$uid} //= $Self->{db}->read_jevent_payload($uid) // {};

    if ($condition->{after} || $condition->{before}) {
      my $start      = $payload->{start} // '';
      my $is_recur   = $payload->{recurrenceRule};
      unless ($is_recur) {
        # draft-ietf-jmap-calendars S5.10: before/after are local date-times
        # in the query's timeZone (default Etc/UTC); compare as instants,
        # the event in its own time zone (a floating one in the query's).
        my $qtz = $Self->{_query_tz} // 'Etc/UTC';
        my $ev_start = _parse_jscal_dt($start, $payload->{timeZone} // $qtz);
        my $ev_end   = $ev_start && (_dt_add_duration($ev_start, $payload->{duration} // 'PT0S') // $ev_start);
        if (my $bound = $condition->{before} and $ev_start) {
          my $bdt = _parse_jscal_dt($bound =~ s/Z$//r, $qtz);
          return 0 if $bdt && DateTime->compare($ev_start, $bdt) >= 0;
        }
        if (my $bound = $condition->{after} and $ev_end) {
          my $adt = _parse_jscal_dt($bound =~ s/Z$//r, $qtz);
          return 0 if $adt && DateTime->compare($ev_end, $adt) <= 0;
        }
      }
    }

    if (defined $condition->{title}) {
      return 0 unless index(lc($payload->{title} // ''), lc($condition->{title})) >= 0;
    }

    if (defined $condition->{description}) {
      return 0 unless index(lc($payload->{description} // ''), lc($condition->{description})) >= 0;
    }

    if (defined $condition->{location}) {
      my $needle = lc($condition->{location});
      my $found  = 0;
      for my $loc (values %{$payload->{locations} || {}}) {
        if (index(lc($loc->{name} // ''), $needle) >= 0) { $found = 1; last }
      }
      return 0 unless $found;
    }

    if (defined $condition->{owner}) {
      my $needle = lc($condition->{owner});
      my $found  = 0;
      if (my $addr = $payload->{organizerCalendarAddress}) {
        (my $e = $addr) =~ s/^mailto://i;
        $found = 1 if index(lc($e), $needle) >= 0;
      }
      unless ($found) {
        for my $p (values %{$payload->{participants} || {}}) {
          next unless ($p->{roles} || {})->{owner};
          my $addr = $p->{calendarAddress} // '';
          (my $e = $addr) =~ s/^mailto://i;
          if (index(lc($p->{name} // ''), $needle) >= 0 ||
              index(lc($e), $needle) >= 0) { $found = 1; last }
        }
      }
      return 0 unless $found;
    }

    if (defined $condition->{attendee}) {
      my $needle = lc($condition->{attendee});
      my $found  = 0;
      for my $p (values %{$payload->{participants} || {}}) {
        my $addr = $p->{calendarAddress} // '';
        (my $e = $addr) =~ s/^mailto://i;
        if (index(lc($p->{name} // ''), $needle) >= 0 ||
            index(lc($e), $needle) >= 0) { $found = 1; last }
      }
      return 0 unless $found;
    }

    if (defined $condition->{text}) {
      my $needle   = lc($condition->{text});
      my @hayparts = (
        $payload->{title}       // '',
        $payload->{description} // '',
        map { $_->{name} // '' } values %{$payload->{locations}    || {}},
        map {
          my $p = $_;
          my $addr = $p->{calendarAddress} // '';
          (my $e = $addr) =~ s/^mailto://i;
          ($p->{name} // ''), $e
        } values %{$payload->{participants} || {}},
      );
      return 0 unless index(lc(join(' ', @hayparts)), $needle) >= 0;
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

my %CALENDAR_EVENT_FILTER_PROPS = map { $_ => 1 }
  qw(inCalendar inCalendars uid after before text title description location owner attendee);

my %CALENDAR_EVENT_SORT = map { $_ => 1 } qw(start uid recurrenceId);

# Sort query entries ({ id, start, uid, recurrenceId }) by a list of
# Comparators; a null recurrenceId (a base event) sorts first, and the id
# breaks ties so the order is total.
sub _sort_calendar_events {
  my ($items, $sort) = @_;
  my %keys;
  return sort {
    my $res = 0;
    for my $cmp (@$sort) {
      my $p = $cmp->{property};
      if ($p eq 'uid') {
        $res = JMAP::Collation::compare($cmp->{collation}, $a->{uid}, $b->{uid}, \%keys);
      } else {
        my ($x, $y) = ($a->{$p}, $b->{$p});
        $res = !defined $x ? (defined $y ? -1 : 0) : !defined $y ? 1 : $x cmp $y;
      }
      $res = -$res if defined($cmp->{isAscending}) && !$cmp->{isAscending};
      last if $res;
    }
    $res || ($a->{id} cmp $b->{id});
  } @$items;
}

sub api_CalendarEvent_query {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  if ($args->{filter}) {
    my @e = $Self->_check_filter($args->{filter}, \%CALENDAR_EVENT_FILTER_PROPS);
    return @e if @e;
  }

  my $newQueryState = "$user->{jstateCalendarEvent}";

  my $data = $Self->{db}->dget('jevents', { active => 1 }, 'eventuid,jcalendarid,jcalendarids');


  local $Self->{_query_tz} = $args->{timeZone} // 'Etc/UTC';
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['timeZone']}])
    unless _parse_jscal_dt('2000-01-01T00:00:00', $Self->{_query_tz});

  # S5.10: start, uid and recurrenceId "MUST be supported for sorting"
  for my $cmp (@{$args->{sort} // []}) {
    return $Self->_transError(['error', {type => 'unsupportedSort', sort => $cmp}])
      unless ref $cmp eq 'HASH' && $CALENDAR_EVENT_SORT{$cmp->{property} // ''};
  }

  if ($args->{expandRecurrences}) {
    # S5.10: with expandRecurrences "the filter MUST be just a FilterCondition
    # (not a FilterOperator) and MUST include both a before and after
    # property", so the server is never asked for infinitely many results
    my $f = $args->{filter};
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['filter'],
        description => 'expandRecurrences needs a FilterCondition with both before and after'}])
      unless ref $f eq 'HASH' && !exists $f->{operator}
          && defined $f->{after} && defined $f->{before};
    my $filter  = $args->{filter} // {};
    my $after   = $filter->{after};
    my $before  = $filter->{before};
    my %storage;

    # inCalendar / inCalendars pre-filter (avoids loading payloads for wrong calendars)
    if ($filter->{inCalendar}) {
      $data = [ grep { my $r = $_; grep { $_ eq $filter->{inCalendar} } JMAP::DB::event_calendar_ids($r) } @$data ];
    }
    if ($filter->{inCalendars}) {
      my %cal_set = map { $_ => 1 } @{$filter->{inCalendars}};
      $data = [ grep { grep { $cal_set{$_} } JMAP::DB::event_calendar_ids($_) } @$data ];
    }

    my @expanded;
    for my $row (@$data) {
      my $master = $Self->{db}->read_jevent_payload($row->{eventuid});
      next unless $master;

      $storage{ $row->{eventuid} } = $master;
      next unless $Self->_event_match($row, $filter, \%storage);

      my $is_recurring = $master->{recurrenceRule};
      if ($is_recurring) {
        # an instance with no id (one too long for RFC 8620 S1.2) is not offered
        push @expanded, map { { %$_, uid => $row->{eventuid}, recurrenceId => $_->{rid} } }
                        grep { defined $_->{id} }
                        $Self->_expand_event_occurrences($row, $master, $after, $before);
      } else {
        push @expanded, { id => JMAP::EventId::master_id($row->{eventuid}),
                          start => $master->{start} // '',
                          uid => $row->{eventuid}, recurrenceId => undef };
      }
    }

    @expanded = _sort_calendar_events(\@expanded, $args->{sort} || [{ property => 'start' }]);

    my ($wstart, $wend) = $Self->_apply_window(\@expanded, $args, sub { $_[0]{id} });
    return $Self->_transError(['error', {type => 'anchorNotFound'}]) unless defined $wstart;

    my @ids = map { $expanded[$_]{id} } $wstart..$wend;
    my $total = scalar @expanded;

    $Self->commit();

    return ['CalendarEvent/query', {
      accountId          => $accountid,
      filter             => $args->{filter},
      sort               => $args->{sort},
      queryState         => $newQueryState,
      canCalculateChanges => JSON::false,
      position           => $wstart,
      total              => $total,
      ids                => [map { "$_" } @ids],
    }];
  }

  my %storage;
  $data = $Self->_event_filter($data, $args->{filter}, \%storage) if $args->{filter};

  if ($args->{sort}) {
    for my $row (@$data) {
      $storage{$row->{eventuid}} //= $Self->{db}->read_jevent_payload($row->{eventuid}) // {};
      $row->{start}        = $storage{$row->{eventuid}}{start} // '';
      $row->{uid}          = $row->{eventuid};
      $row->{recurrenceId} = undef;   # a stored event is a base event
      $row->{id}           = $row->{eventuid};
    }
    $data = [_sort_calendar_events($data, $args->{sort})];
  }

  my ($start, $end) = $Self->_apply_window($data, $args,
    sub { JMAP::EventId::master_id($_[0]{eventuid}) });
  return $Self->_transError(['error', {type => 'anchorNotFound'}]) unless defined $start;

  my @result = map { JMAP::EventId::master_id($data->[$_]{eventuid}) } $start..$end;

  $Self->commit();

  # The snapshot keeps UIDs; queryChanges turns them into ids as it answers.
  $Self->{db}->save_query('CalendarEvent', {
    filter => $args->{filter},
    sort   => $args->{sort},
  }, $newQueryState, [map { $_->{eventuid} } @$data]);

  return ['CalendarEvent/query', {
    accountId           => $accountid,
    filter              => $args->{filter},
    sort                => $args->{sort},
    queryState          => $newQueryState,
    canCalculateChanges => JSON::true,
    position            => $start,
    total               => scalar(@$data),
    ids                 => [map { "$_" } @result],
  }];
}

# One occurrence of a recurring event as an event of its own (undef if
# excluded): Text::JSCalendar applies the override patch, pointer paths like
# participants/<id>/participationStatus included, sets recurrenceId and
# start, and drops the master-only properties.
sub _expand_occurrence {
  my ($master, $recurrence_id) = @_;
  return Text::JSCalendar->instance($master, $recurrence_id);
}

# draft-ietf-jmap-calendars S5.7: with reduceParticipants, "only participants
# with the owner role or corresponding to the user's participant identities
# will be returned" -- in the event and in its recurrence overrides.
sub _reduce_participants {
  my ($item, $mine) = @_;
  my %gone;
  my $keep = sub {
    my $p = shift;
    return 0 unless ref $p eq 'HASH';
    return 1 if ref $p->{roles} eq 'HASH' && $p->{roles}{owner};
    return $mine->{lc($p->{calendarAddress} // '')} ? 1 : 0;
  };
  my $reduce = sub {
    my $parts = shift;
    return unless ref $parts eq 'HASH';
    for my $id (keys %$parts) {
      next if $keep->($parts->{$id});
      delete $parts->{$id};
      $gone{$id} = 1;
    }
  };
  $reduce->($item->{participants});
  if (ref $item->{recurrenceOverrides} eq 'HASH') {
    for my $override (values %{$item->{recurrenceOverrides}}) {
      next unless ref $override eq 'HASH';
      $reduce->($override->{participants});
    }
    for my $override (values %{$item->{recurrenceOverrides}}) {
      next unless ref $override eq 'HASH';
      for my $key (keys %$override) {
        delete $override->{$key}
          if $key =~ m{^participants/([^/]+)} && ($gone{$1} || !exists $item->{participants}{$1});
      }
    }
  }
}

sub api_CalendarEvent_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateCalendarEvent}";

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['ids']}])
    unless $args->{ids};
  for my $arg (qw(recurrenceOverridesBefore recurrenceOverridesAfter)) {
    next unless defined $args->{$arg};
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => [$arg]}])
      unless !ref $args->{$arg} && $args->{$arg} =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z\z/;
  }
  if (defined $args->{timeZone}) {
    require DateTime::TimeZone;
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['timeZone']}])
      unless !ref $args->{timeZone} && eval { DateTime::TimeZone->new(name => $args->{timeZone}) };
  }
  # compare as UTC strings without fractions
  local $args->{recurrenceOverridesBefore} = defined $args->{recurrenceOverridesBefore}
    ? substr($args->{recurrenceOverridesBefore}, 0, 19) . 'Z' : undef;
  local $args->{recurrenceOverridesAfter} = defined $args->{recurrenceOverridesAfter}
    ? substr($args->{recurrenceOverridesAfter}, 0, 19) . 'Z' : undef;

  my %seenids;
  my %missingids;
  my @list;
  # the user's participant identities (see ParticipantIdentity/get)
  my $mine = { map { lc("mailto:$_") => 1 } grep { length } $user->{email} // '' };
  my $resolve = $Self->_event_id_resolver();
  foreach my $id (map { $Self->idmap($_) } @{$args->{ids}}) {
    next unless defined $id;
    next if $seenids{$id}++;

    my ($eventuid, $recurrence_id) = $resolve->($id);
    unless (defined $eventuid) {
      $missingids{$id} = 1;
      next;
    }

    # One instance of a recurring event
    if (defined $recurrence_id) {
      my $master_uid = $eventuid;

      my $data = $Self->{db}->dgetone('jevents', { eventuid => $master_uid, active => 1 }, 'jcalendarid,jcalendarids');
      unless ($data) {
        $missingids{$id} = 1;
        next;
      }

      my $master = $Self->{db}->read_jevent_payload($master_uid);
      unless ($master) {
        $missingids{$id} = 1;
        next;
      }

      my $item = _expand_occurrence($master, $recurrence_id);
      unless ($item) {
        $missingids{$id} = 1;  # excluded occurrence
        next;
      }

      my $organizer = $item->{organizerCalendarAddress};
      _reduce_participants($item, $mine) if $args->{reduceParticipants};
      my %computed = _calendar_event_computed_props($item, $args);
      foreach my $key (keys %$item) {
        delete $item->{$key} unless _prop_wanted($args, $key);
      }
      # S5.8: on an expanded instance these "MUST be returned as null if requested"
      $item->{$_} = undef for grep { _prop_wanted($args, $_) } qw(recurrenceRule recurrenceOverrides);
      %$item = (%$item, %computed);
      $item->{id}          = $id;
      $item->{calendarIds} = { map { ("$_" => JSON::true) } JMAP::DB::event_calendar_ids($data) } if _prop_wanted($args, 'calendarIds');
      $item->{isOrigin}    = _is_origin($organizer, $user->{email})   if _prop_wanted($args, 'isOrigin');
      $item->{isDraft}     = $JSON::false if _prop_wanted($args, 'isDraft');
      # draft-ietf-jmap-calendars S10.9.2: set only on a synthetic instance id,
      # and it names the real event the instance was generated from.
      $item->{baseEventId} = JMAP::EventId::master_id($master_uid) if _prop_wanted($args, 'baseEventId');
      push @list, $item;
      next;
    }

    # Master event
    my $data = $Self->{db}->dgetone('jevents', { eventuid => $eventuid, active => 1 }, 'jcalendarid,jcalendarids');
    unless ($data) {
      $missingids{$id} = 1;
      next;
    }

    my $item = $Self->{db}->read_jevent_payload($eventuid);
    unless ($item) {
      $missingids{$id} = 1;
      next;
    }

    my $organizer = $item->{organizerCalendarAddress};
    $item->{uid} //= $eventuid;
    _reduce_participants($item, $mine) if $args->{reduceParticipants};
    _window_overrides($item, $args);
    my %computed = _calendar_event_computed_props($item, $args);
    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }
    %$item = (%$item, %computed);

    $item->{id}          = $id;
    $item->{calendarIds} = { map { ("$_" => JSON::true) } JMAP::DB::event_calendar_ids($data) } if _prop_wanted($args, 'calendarIds');
    $item->{isOrigin}    = _is_origin($organizer, $user->{email})   if _prop_wanted($args, 'isOrigin');
    $item->{isDraft}     = $JSON::false if _prop_wanted($args, 'isDraft');
    $item->{baseEventId} = undef        if _prop_wanted($args, 'baseEventId');

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
  # an event's id changed past this state (schema v13): ids are not reportable
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if $user->{jeventidcut} && $args->{sinceState} =~ /\A\d+\z/ && $args->{sinceState} <= $user->{jeventidcut};

  my $data = $Self->{db}->dget('jevents', { jmodseq => ['>', $args->{sinceState}] }, 'eventuid,active,jcreated,jmodseq');
  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless defined $data;

  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'eventuid');
  my $ids = sub { [ map { JMAP::EventId::master_id($_) } @{$_[0]} ] };

  my @res;
  push @res, ['CalendarEvent/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => $ids->($created),
    updated => $ids->($updated),
    destroyed => $ids->($destroyed),
    hasMoreChanges => $partial ? JSON::true : JSON::false,
  }];

  return @res;
}

sub api_CalendarEvent_queryChanges {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  if ($args->{filter}) {
    my @e = $Self->_check_filter($args->{filter}, \%CALENDAR_EVENT_FILTER_PROPS);
    return @e if @e;
  }

  my $newQueryState = "$user->{jstateCalendarEvent}";
  my $sinceQueryState = $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    unless $sinceQueryState;
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $sinceQueryState <= $user->{jdeletedmodseq})
    or ($user->{jeventidcut} and $sinceQueryState <= $user->{jeventidcut});

  my $data = $Self->{db}->dget('jevents', { active => 1 }, 'eventuid,jcalendarid,jcalendarids,jmodseq');

  $Self->commit();

  my $qparams = { filter => $args->{filter}, sort => $args->{sort} };
  my $old_ids = $Self->{db}->load_query('CalendarEvent', $qparams, $sinceQueryState);

  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    unless defined $old_ids;

  my %storage;
  $data = $Self->_event_filter($data, $args->{filter}, \%storage) if $args->{filter};

  if ($args->{sort}) {
    # the same order CalendarEvent/query gives
    for my $cmp (@{$args->{sort}}) {
      return $Self->_transError(['error', {type => 'unsupportedSort', sort => $cmp}])
        unless ref $cmp eq 'HASH' && $CALENDAR_EVENT_SORT{$cmp->{property} // ''};
    }
    for my $row (@$data) {
      $storage{$row->{eventuid}} //= $Self->{db}->read_jevent_payload($row->{eventuid}) // {};
      $row->{start}        = $storage{$row->{eventuid}}{start} // '';
      $row->{uid}          = $row->{eventuid};
      $row->{recurrenceId} = undef;
      $row->{id}           = $row->{eventuid};
    }
    $data = [_sort_calendar_events($data, $args->{sort})];
  }

  my @new_ids = map { $_->{eventuid} } @$data;

  # Only the uid is immutable: with any filter, or a sort on anything else,
  # each event changed since the old state is reported (RFC 8620 S5.6).
  my %changed;
  if ($args->{filter} or grep { ($_->{property} // '') ne 'uid' } @{$args->{sort} || []}) {
    %changed = map { $_->{eventuid} => 1 }
               grep { ($_->{jmodseq} // 0) > $sinceQueryState } @$data;
  }
  my ($removed, $added) = JMAP::QueryChanges::diff($old_ids, \@new_ids, \%changed);

  return $Self->_transError(['error', {type => 'tooManyChanges', newQueryState => $newQueryState}])
    if $args->{maxChanges} and @$removed + @$added > $args->{maxChanges};

  $Self->{db}->save_query('CalendarEvent', $qparams, $newQueryState, \@new_ids);

  return ['CalendarEvent/queryChanges', {
    accountId     => $accountid,
    filter        => $args->{filter},
    sort          => $args->{sort},
    oldQueryState => "$sinceQueryState",
    newQueryState => $newQueryState,
    total         => scalar(@new_ids),
    # The snapshots hold UIDs; the answer holds ids.
    removed       => [map { JMAP::EventId::master_id($_) } @$removed],
    added         => [map { +{ %$_, id => JMAP::EventId::master_id($_->{id}) } } @$added],
  }];
}


sub api_CalendarEvent_parse {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['blobIds']}])
    unless $args->{blobIds} && ref($args->{blobIds}) eq 'ARRAY';

  $Self->commit();

  my %parsed;
  my @notParsable;
  my @notFound;

  my $jscal = Text::JSCalendar->new();

  for my $blobId (@{$args->{blobIds}}) {
    my ($type, $content) = $Self->{db}->get_blob($blobId);
    unless (defined $content && length $content) {
      push @notFound, $blobId;
      next;
    }

    my @events = eval { $jscal->vcalendarToEvents($content) };
    if ($@ || !@events) {
      push @notParsable, $blobId;
      next;
    }

    for my $event (@events) {
      delete $event->{calendarIds};
    }

    $parsed{$blobId} = \@events;
  }

  return ['CalendarEvent/parse', {
    accountId  => $accountid,
    parsed     => \%parsed,
    notFound   => \@notFound,
    notParsable => \@notParsable,
  }];
}

sub _busy_status_for_event {
  my ($payload, $user_email) = @_;
  my $status = $payload->{status} // 'confirmed';

  if ($user_email && ref $payload->{participants} eq 'HASH') {
    for my $p (values %{$payload->{participants}}) {
      my $p_email = $p->{email};
      if (!$p_email && $p->{calendarAddress}) {
        ($p_email = $p->{calendarAddress}) =~ s/^mailto://i;
      }
      next unless $p_email && lc($p_email) eq lc($user_email);
      my $ps = $p->{participationStatus} // 'needs-action';
      return 'confirmed' if $ps eq 'accepted' && $status eq 'confirmed';
      return 'tentative'  if $ps eq 'tentative' || $status eq 'tentative';
      return 'unavailable';
    }
  }

  return 'confirmed'  if $status eq 'confirmed';
  return 'tentative'  if $status eq 'tentative';
  return 'unavailable';
}

sub api_Principal_getAvailability {
  my ($Self, $args) = @_;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  return $Self->_transError(['error', {type => 'notFound'}])
    unless ($args->{id} // '') eq 'me';

  my $utc_start    = $args->{utcStart};
  my $utc_end      = $args->{utcEnd};
  my $show_details = $args->{showDetails} // 0;

  # maxAvailabilityDuration (P366D) bounds the range: "tooLarge" beyond it.
  {
    my ($s, $e) = map { Date::Parse::str2time($_) } $utc_start, $utc_end;
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['utcStart', 'utcEnd']}])
      unless defined $s && defined $e && $e >= $s;
    return $Self->_transError(['error', {type => 'tooLarge'}])
      if $e - $s > 366 * 86400;
  }
  my $event_props  = $args->{eventProperties};

  (my $range_start = $utc_start) =~ s/Z$//;
  (my $range_end   = $utc_end)   =~ s/Z$//;

  my $user_email = $user->{email};
  my $jevents    = $Self->{db}->dget('jevents', {active => 1}, 'eventuid,jcalendarid,jcalendarids');
  $Self->commit();

  my @busy;

  for my $row (@$jevents) {
    my $payload = $Self->{db}->read_jevent_payload($row->{eventuid});
    next unless $payload;

    next if ($payload->{freeBusyStatus} // 'busy') eq 'free';
    next if ($payload->{status}         // 'confirmed') eq 'cancelled';
    next if ($payload->{privacy}        // 'public') eq 'secret';

    my $is_recurring = $payload->{recurrenceRule};

    my @candidates;  # each is {occ_payload, local_start}
    if ($is_recurring) {
      my @occurrences = $Self->_expand_event_occurrences($row, $payload, $range_start, $range_end);
      for my $occ (@occurrences) {
        my $rid = $occ->{rid};
        my $op = $rid ? (_expand_occurrence($payload, $rid) // next) : $payload;
        next if ($op->{freeBusyStatus} // $payload->{freeBusyStatus} // 'busy') eq 'free';
        next if ($op->{status}         // $payload->{status} // 'confirmed') eq 'cancelled';
        next if ($op->{privacy}        // $payload->{privacy} // 'public') eq 'secret';
        push @candidates, {occ_payload => $op, local_start => $occ->{start}};
      }
    } else {
      push @candidates, {occ_payload => $payload, local_start => $payload->{start}};
    }

    for my $c (@candidates) {
      my ($op, $local_start) = @{$c}{qw(occ_payload local_start)};
      my $tz  = $op->{timeZone} // $payload->{timeZone} // 'UTC';
      my $dur = $op->{duration} // $payload->{duration} // 'P0D';

      my $us = _utc_start($local_start, $tz);
      next unless defined $us;  # skip all-day events
      next if $us ge $utc_end;

      my $dt_us = _parse_jscal_dt($local_start, $tz);
      my $dt_ue = $dt_us ? _dt_add_duration($dt_us, $dur) : undef;
      $dt_ue //= $dt_us;
      my $ue = ($dt_ue ? do { $dt_ue->set_time_zone('UTC'); $dt_ue->strftime('%Y-%m-%dT%H:%M:%SZ') } : $us);
      next if $ue le $utc_start;

      my %bp = (
        utcStart   => $us,
        utcEnd     => $ue,
        busyStatus => _busy_status_for_event($op, $user_email),
        event      => JSON::null,
        accountId  => JSON::null,
      );
      if ($show_details && ($op->{privacy} // 'public') ne 'private') {
        my $ev = $event_props
          ? { map { $_ => $op->{$_} } grep { exists $op->{$_} } @$event_props }
          : $op;
        $bp{event}     = $ev;
        $bp{accountId} = $accountid;
      }
      push @busy, \%bp;
    }
  }

  # "the server MUST merge and split BusyPeriod objects where the event
  # property is null, such that none of them overlap and either there is a
  # gap ... or those objects have a different busyStatus", choosing
  # "confirmed > unavailable > tentative" where they overlap.
  my @detailed = grep { ref $_->{event} } @busy;
  my @plain    = grep { !ref $_->{event} } @busy;
  my %rank = (confirmed => 3, unavailable => 2, tentative => 1);
  my %points = map { $_ => 1 } map { ($_->{utcStart}, $_->{utcEnd}) } @plain;
  my @points = sort keys %points;
  my @merged;
  for my $i (0 .. $#points - 1) {
    my ($from, $to) = @points[$i, $i + 1];
    my ($status) = sort { $rank{$b} <=> $rank{$a} }
                   map { $_->{busyStatus} // 'unavailable' }
                   grep { $_->{utcStart} le $from && $_->{utcEnd} ge $to } @plain;
    next unless $status;
    if (@merged && $merged[-1]{utcEnd} eq $from && $merged[-1]{busyStatus} eq $status) {
      $merged[-1]{utcEnd} = $to;
    }
    else {
      push @merged, { utcStart => $from, utcEnd => $to, busyStatus => $status,
                      event => JSON::null, accountId => JSON::null };
    }
  }

  @busy = sort { $a->{utcStart} cmp $b->{utcStart} } @detailed, @merged;

  return ['Principal/getAvailability', {
    accountId => $accountid,
    list      => \@busy,
  }];
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
  for my $cid (keys %$created) {
    $created->{$cid}{id} = JMAP::EventId::master_id($created->{$cid}{id});
    $Self->setid($cid, $created->{$cid}{id});
  }
  my $patchInvalid = $Self->_resolve_patch($update, 'api_CalendarEvent_get');

  # The client's ids become what ImapDB works on: the UID, or "UID/recurrenceId"
  # for one instance.  The results go back under the ids the client sent.
  my (%update_by_key, %update_id, @destroy_keys, %destroy_id);
  my (%unknown_update, %unknown_destroy);
  $Self->begin();
  my $resolve = $Self->_event_id_resolver();
  for my $id (keys %$update) {
    my ($uid, $rid) = $resolve->($Self->idmap($id));
    unless (defined $uid) {
      $unknown_update{$id} = { type => 'notFound', description => 'No such event' };
      next;
    }
    my $key = defined $rid ? "$uid/$rid" : $uid;
    $update_by_key{$key} = $update->{$id};
    $update_id{$key} = $id;
  }
  for my $id (@$destroy) {
    my ($uid, $rid) = $resolve->($Self->idmap($id));
    unless (defined $uid) {
      $unknown_destroy{$id} = { type => 'notFound', description => 'No such event' };
      next;
    }
    my $key = defined $rid ? "$uid/$rid" : $uid;
    push @destroy_keys, $key;
    $destroy_id{$key} = $id;
  }
  $Self->commit();

  ($updated, $notUpdated) = $Self->{db}->update_calendar_events(\%update_by_key, sub { $Self->idmap(shift) });
  $updated    = { map { ($update_id{$_} // $_) => $updated->{$_} } keys %$updated };
  $notUpdated = { %unknown_update,
                  (map { ($update_id{$_} // $_) => $notUpdated->{$_} } keys %{$notUpdated || {}}),
                  %$patchInvalid };   # RFC 8620 S5.3
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendar_events(\@destroy_keys);
  $destroyed    = [ map { $destroy_id{$_} // $_ } @$destroyed ];
  $notDestroyed = { %unknown_destroy,
                    map { ($destroy_id{$_} // $_) => $notDestroyed->{$_} } keys %$notDestroyed };

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

  # The account's one identity. draft-ietf-jmap-calendars S4.1: isDefault
  # "SHOULD be true for exactly one participant identity".
  my $identity = sub {
    my %id = (id => 'id1', name => '', calendarAddress => "mailto:$email",
              isDefault => JSON::true);
    return \%id unless $args->{properties};
    my %want = map { $_ => 1 } @{$args->{properties}}, 'id';   # RFC 8620 S5.1
    return { map { $_ => $id{$_} } grep { $want{$_} } keys %id };
  };

  if ($args->{ids}) {
    for my $id (@{$args->{ids}}) {
      if ($email && $id eq 'id1') {
        push @identities, $identity->();
      } else {
        push @notFound, "$id";
      }
    }
  } elsif ($email) {
    push @identities, $identity->();
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
  my %notCreated  = map { $_ => { type => 'forbidden' } } keys %{$args->{create}  || {}};
  my %notUpdated  = map { $_ => { type => 'forbidden' } } keys %{$args->{update}  || {}};
  my %notDestroyed = map { $_ => { type => 'forbidden' } } @{$args->{destroy} || []};
  return ['ParticipantIdentity/set', {
    accountId    => $accountid,
    oldState     => $state,
    newState     => $state,
    created      => undef,
    notCreated   => _nullempty(\%notCreated),
    updated      => undef,
    notUpdated   => _nullempty(\%notUpdated),
    destroyed    => undef,
    notDestroyed => _nullempty(\%notDestroyed),
  }];
}

# draft-ietf-jmap-calendars S7: a CalendarEventNotification records a change
# another user made to an event the user can see.  The proxy has no calendar
# sharing, so nobody else ever changes this account's events: the set is
# always empty and its state never moves.
sub api_CalendarEventNotification_get {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  $Self->commit();
  return ['CalendarEventNotification/get', {
    accountId => $accountid,
    state     => '0',
    list      => [],
    notFound  => [ map { "$_" } @{$args->{ids} || []} ],
  }];
}

sub api_CalendarEventNotification_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  $Self->commit();
  return ['error', { type => 'cannotCalculateChanges' }]
    unless ($args->{sinceState} // '') eq '0';
  return ['CalendarEventNotification/changes', {
    accountId => $accountid, oldState => '0', newState => '0',
    hasMoreChanges => JSON::false, created => [], updated => [], destroyed => [],
  }];
}

sub api_CalendarEventNotification_set {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  $Self->commit();
  return ['error', { type => 'stateMismatch' }]
    if defined $args->{ifInState} && $args->{ifInState} ne '0';
  # S7.3: "Only destroy is supported; any attempt to create/update MUST be
  # rejected with a forbidden SetError."
  my %notCreated   = map { $_ => { type => 'forbidden' } } keys %{$args->{create} || {}};
  my %notUpdated   = map { $_ => { type => 'forbidden' } } keys %{$args->{update} || {}};
  my %notDestroyed = map { $_ => { type => 'notFound' } } @{$args->{destroy} || []};
  return ['CalendarEventNotification/set', {
    accountId    => $accountid,
    oldState     => '0',
    newState     => '0',
    created      => undef,
    updated      => undef,
    destroyed    => undef,
    notCreated   => %notCreated   ? \%notCreated   : undef,
    notUpdated   => %notUpdated   ? \%notUpdated   : undef,
    notDestroyed => %notDestroyed ? \%notDestroyed : undef,
  }];
}

sub api_CalendarEventNotification_query {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  $Self->commit();
  return ['CalendarEventNotification/query', {
    accountId => $accountid, queryState => '0', canCalculateChanges => JSON::true,
    position => 0, ids => [], total => 0,
  }];
}

sub api_CalendarEventNotification_queryChanges {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_api_init($args);
  $Self->commit();
  return ['error', { type => 'cannotCalculateChanges' }]
    unless ($args->{sinceQueryState} // '') eq '0';
  return ['CalendarEventNotification/queryChanges', {
    accountId => $accountid, oldQueryState => '0', newQueryState => '0',
    removed => [], added => [], total => 0,
  }];
}

1;
