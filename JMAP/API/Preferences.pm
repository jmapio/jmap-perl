package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Encode;

my $json = JSON::XS->new->utf8->canonical();

sub api_Calendar_refreshSynced {
  my $Self = shift;

  $Self->{db}->sync_calendars();

  # no response
  return ['Calendar/refreshSynced', {}];
}

sub _filter_list {
  my $list = shift;
  my $ids = shift;

  return $list unless $ids;

  my %map = map { $_ => 1 } @$ids;

  return [ grep { $map{$_->{id}} } @$list ];
}

sub api_UserPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  my $data = $Self->{db}->dgetcol("juserprefs", {}, 'payload');
  $Self->commit();

  my @list = map { decode_json($_) } @$data;

  my $state = "$user->{jstateUserPreferences}";

# - **remoteServices**: `Object`
#   Maps service type, e.g. 'fs', to an array of services the user has connected to their account, e.g. 'dropbox'.
# - **displayName**: `String`
#   The string to display in the header to identify the account. Normally the email address for the account,
#   but may be different for FastMail users based on a preference).
# - **language**: `String`
#   The language code, e.g. "en-gb", of the user's language
# - **timeZone**: `String`,
#   The Olsen name for the user's time zone.
# - **use24hClock**: `String`
#   One of `'yes'`/`'no'`/`''`. Defaults to '', which means language dependent.
# - **theme**: `String`
#   The name of the theme to use
# - **enableNewsletter**: `booklean`
#   Send newsletters to this account?
# - **defaultIdentityId**: `String`
#   The id of the default personality.
# - **useDefaultFromOnSMTP**: `Boolean`
#   If true, when sending via SMTP the From address will always be set to the default personality,
#   regardless of the address set by the client.
# - **excludeContactsFromBlacklist**: `Boolean`
#   Defaults to true, which means skip the blacklist when processing rules, if the sender of the
#   message is in the user's contacts list.

#   If the language or theme preference is set, the response MUST also set the  appropriate cookie.

  unless (@list) {
    push @list, {
      id => 'singleton',
      remoteServices => {},
      displayName => $user->{displayname} || $user->{email},
      language => 'en-us',
      timeZone => 'Australia/Melbourne',
      use24hClock => 'yes',
      theme => 'default',
      enableNewsletter => $JSON::true,
      defaultIdentityId => 'id1',
      useDefaultFromOnSMTP => $JSON::false,
      excludeContactsFromBlacklist => $JSON::false,
    };
  }

  return ['UserPreferences/get', {
    accountId => $accountid,
    state => $state,
    list => _filter_list(\@list, $args->{ids}),
    notFound => [],
  }];
}

sub update_singleton_value {
  my $Self = shift;
  my $fun = shift;
  my $update = shift;

  my $data = $Self->$fun({ids => ['singleton']});
  my $old = $data->[1]{list}[0];
  foreach my $key (keys %$update) {
    $old->{$key} = $update->{$key};
  }

  return $old;
}

sub api_UserPreferences_set {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  $Self->commit();

  my $oldState = "$user->{jstateUserPreferences}";

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my $created = {};
  my $notCreated = { map { $_ => "Can't create singleton types" } keys %$create };
  my $updated = {};
  my $notUpdated = {};
  foreach my $key (keys %$update) {
    if ($key eq 'singleton') {
      my $value = $Self->update_singleton_value('api_UserPreferences_get', $update->{singleton});
      eval { $Self->{db}->update_prefs('UserPreferences', $value) };
      if ($@) {
        $notUpdated->{singleton} = "$@";
      }
      else {
        $updated->{singleton} = $JSON::true,
      }
    }
    else {
      $notUpdated->{$key} = "Can't update anything except singleton";
    }
  }
  my $destroyed = [];
  my $notDestroyed = { map { $_ => "Can't delete singleton types" } @$destroy };

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  my $newState = "$user->{jstateUserPreferences}";

  my @res;
  push @res, ['UserPreferences/set', {
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

sub api_ClientPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  my $data = $Self->{db}->dgetcol("jclientprefs", {}, 'payload');
  $Self->commit();

  my @list = map { eval {decode_json($_)} || () } @$data;

  my $state = "$user->{jstateClientPreferences}";

# - **remoteServices**: `Object`

# - **useSystemFont**: `Boolean`
#   Should the system font be used for the UI rather than FastMail's custom font?
# - **enableKBShortcuts**: `Boolean`
#   Activate keyboard shortcuts?
# - **enableConversations**: `Boolean`
#   Group messages into conversations?
# - **deleteEntireConversation**: `Boolean`
#   Should deleting a conversation delete messages from all folders?
# - **showDeleteWarning**: `Boolean`
#   Should a warning be shown on delete?
# - **showSidebar**: `Boolean`
#   Show a sidebar?
# - **showReadingPane**: `Boolean`
#   Show a reading pane or use separate screens?
# - **showPreview**: `Boolean`
#   Show a preview line on the mailbox screen?
# - **showAvatar**: `Boolean`
#   Show avatars of senders?
# - **afterActionGoTo**: `String`
#   One of `"next"`/`"prev"`/`"mailbox"`. Determines which screen to show
#   next after performing an action in the conversation view.
# - **viewTextOnly**: `Boolean`
#   If true, HTML messages will be converted to plain text before being shown,

  unless (@list) {
    push @list, {
      id => 'singleton',
      useSystemFont => $JSON::false,
      enableKBShortcuts => $JSON::true,
      enableConversations => $JSON::true,
      deleteEntireConversation => $JSON::true,
      showDeleteWarning => $JSON::true,
      showSidebar => $JSON::true,
      showReadingPane => $JSON::false,
      showPreview => $JSON::true,
      showAvatar => $JSON::true,
      afterActionGoTo => 'mailbox',
      viewTextOnly => $JSON::false,
      allowExternalContent => 'always',
      extraHeaders => [],
      autoSaveContacts => $JSON::true,
      replyFromDefault => $JSON::true,
      defaultReplyAll => $JSON::true,
      composeInHTML => $JSON::true,
      replyInOrigFormat => $JSON::true,
      defaultFont => undef,
      defaultSize => undef,
      defaultColour => undef,
      sigPositionOnReply => 'before',
      sigPositionOnForward => 'before',
      replyQuoteAs => 'inline',
      forwardQuoteAs => 'inline',
      replyAttribution => '',
      canWriteSharedContacts => $JSON::false,
      contactsSort => 'lastName',
    };
  }

  return ['ClientPreferences/get', {
    accountId => $accountid,
    state => $state,
    list => _filter_list(\@list, $args->{ids}),
    notFound => [],
  }];
}

sub api_ClientPreferences_set {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my $oldState = "$user->{jstateClientPreferences}";

  my $created = {};
  my $notCreated = { map { $_ => "Can't create singleton types" } keys %$create };
  my $updated = {};
  my $notUpdated = {};
  foreach my $key (keys %$update) {
    if ($key eq 'singleton') {
      my $value = $Self->update_singleton_value('api_ClientPreferences_get', $update->{singleton});
      $updated->{singleton} = eval { $Self->{db}->update_prefs('ClientPreferences', $value) };
      $notUpdated->{singleton} = $@ if $@;
    }
    else {
      $notUpdated->{$key} = "Can't update anything except singleton";
    }
  }
  my $destroyed = [];
  my $notDestroyed = { map { $_ => "Can't delete singleton types" } @$destroy };

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  my $newState = "$user->{jstateClientPreferences}";

  my @res;
  push @res, ['ClientPreferences/set', {
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

sub api_CalendarPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  my $data = $Self->{db}->dgetcol("jcalendarprefs", {}, 'payload');
  my $defaultCalendar = $Self->{db}->dgetfield('jcalendars', { active => 1 }, 'jcalendarid');
  my ($archiveId) = $Self->{db}->dgetfield('jmailboxes', { role => 'archive', active => 1 }, 'jmailboxid');
  $Self->commit();

  my @list = map { decode_json($_) } @$data;

  my $state = "$user->{jstateCalendarPreferences}";

#- **useTimeZones**: `Boolean`
#  If true, enables multiple time zone support.
#- **firstDayOfWeek**: `Number`
#  0 => Sunday, 1 => Monday, etc. Initially defaults to 1.
#- **showWeekNumbers**: `Boolean`
#  If true, shows week number in overview screen.
#- **showDeclined**: `Boolean`
#  If true, show events that you have RSVPed "no" to.
#- **birthdaysAreVisible**: `Boolean`
#  Should birthdays be shown on the calendar?
#- **defaultCalendarId**: `String`
#  The id of the user's default calendar.
#- **defaultAlerts**: `Alert[]|null`
#  See getCalendarEvents for description of an Alert object.
#- **defaultAllDayAlerts**: `Alert[]|null`
#  See getCalendarEvents for description of an Alert object.
#- **autoAddInvitations**: `Boolean`
#  If true, whenever an event invitation is received, add the event to the user's calendar with the id given in *autoAddCalendarId*.
#- **autoAddCalendarId**: `String`
#  The id of the calendar to auto-add to.
#- **onlyAutoAddIfInGroup**: `Boolean`
#  If true, only automatically add the event if the sender of the invitation is in the contact group given by the *autoAddGroupId* preference.
#- **autoAddGroupId**: `String|null`
#  The id of the contact group to auto-add events from, or null for All Contacts.
#- **markReadAndFileAutoAdd**: `Boolean`
#  If true, for emails where the event is auto-added to the calendar, mark the email as read and file in the folder specified by *autoAddFileIn*.
#- **autoAddFileIn**: `String`
#  The id of the folder to file event invitations in; should default to the Archive folder.
#- **autoUpdate**: `Boolean`
#  If true, whenever an update to an event already in the user's calendar is received, update the event in the user's calendar, or delete it if the event is cancelled.
#- **markReadAndFileAutoUpdate**: `Boolean`
#  If true, for emails where the event is auto-updated, mark the email as read and file in the folder specified by *autoUpdateFileIn*.
#- **autoUpdateFileIn**: `String`
#  The id of the folder to file event updates in; should default to the Archive folder.

  unless (@list) {
    push @list, {
      id => 'singleton',
      useTimeZones => $JSON::false,
      firstDayOfWeek => 1,
      showWeekNumbers => $JSON::false,
      showDeclined => $JSON::false,
      birthdaysAreVisible => $JSON::true,
      defaultCalendar => $defaultCalendar,
      defaultAlerts => undef,
      defaultAllDayAlerts => undef,
      autoAddInvitations => $JSON::false,
      autoAddCalendar => $JSON::false,
      onlyAutoAddIfInGroup => $JSON::false,
      autoAddGroup => undef,
      markReadAndFileAutoAdd => $JSON::false,
      autoAddFileIn => $archiveId,
      autoUpdate => $JSON::false,
      markReadAndFileAutoUpdate => $JSON::false,
      autoUpdateFileIn => $archiveId,
    };
  }

  return ['CalendarPreferences/get', {
    accountId => $accountid,
    state => $state,
    list => _filter_list(\@list, $args->{ids}),
  }];
}

sub api_CalendarPreferences_set {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  $Self->commit();

  my $oldState = "$user->{jstateCalendarPreferences}";

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my $created = {};
  my $notCreated = { map { $_ => "Can't create singleton types" } keys %$create };
  my $updated = {};
  my $notUpdated = {};
  foreach my $key (keys %$update) {
    if ($key eq 'singleton') {
      my $value = $Self->update_singleton_value('api_CalendarPreferences_get', $update->{singleton});
      $updated->{singleton} = eval { $Self->{db}->update_prefs('CalendarPreferences', $value) };
      $notUpdated->{singleton} = $@ if $@;
    }
    else {
      $notUpdated->{$key} = "Can't update anything except singleton";
    }
  }
  my $destroyed = [];
  my $notDestroyed = { map { $_ => "Can't delete singleton types" } @$destroy };

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();

  my $newState = "$user->{jstateCalendarPreferences}";

  my @res;
  push @res, ['CalendarPreferences/set', {
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

sub api_VacationResponse_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  return ['VacationResponse/get', {
    accountId => $accountid,
    state => 'dummy',
    list => [{
      id => 'singleton',
      isEnabled => $JSON::false,
      fromDate => undef,
      toDate => undef,
      subject => undef,
      textBody => undef,
      htmlBody => undef,
    }],
    notFound => [],
  }];
}

sub api_Quota_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my @list = (
    {
      id => 'mail',
      used => 1,
      total => 2,
    },
    {
      id => 'files',
      used => 1,
      total => 2,
    },
  );

  return ['Quota/get', {
    accountId => $accountid,
    state => 'dummy',
    list => _filter_list(\@list, $args->{ids}),
    notFound => [],
  }];
}

sub getSavedSearches {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my @list;

  return ['savedSearches', {
    accountId => $accountid,
    state => 'dummy',
    list => \@list,
  }];
}

sub api_Identity_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my @list;
  # XXX todo fix Identity
  push @list, {
    id => "id1",
    displayName => $user->{displayname} || $user->{email},
    mayDelete => $JSON::false,
    email => $user->{email},
    name => $user->{displayname} || $user->{email},
    textSignature => "-- \ntext sig",
    htmlSignature => "-- <br><b>html sig</b>",
    replyTo => $user->{email},
    autoBcc => "",
    addBccOnSMTP => $JSON::false,
    saveSentTo => undef,
    saveAttachments => $JSON::false,
    saveOnSMTP => $JSON::false,
    useForAutoReply => $JSON::false,
    isAutoConfigured => $JSON::true,
    enableExternalSMTP => $JSON::false,
    smtpServer => "",
    smtpPort => 465,
    smtpSSL => "ssl",
    smtpUser => "",
    smtpPassword => "",
    smtpRemoteService => undef,
    popLinkId => undef,
  };

  return ['Identity/get', {
    accountId => $accountid,
    state => 'dummy',
    list => \@list,
    notFound => [],
  }];
}

1;
