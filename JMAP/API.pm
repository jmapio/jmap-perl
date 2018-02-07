#!/usr/bin/perl -cw

package JMAP::API;

use Carp;
use JMAP::DB;
use strict;
use warnings;
use Encode;
use HTML::GenerateUtil qw(escape_html);
use JSON::XS;
use Data::Dumper;

my $json = JSON::XS->new->utf8->canonical();

sub new {
  my $class = shift;
  my $db = shift;

  return bless {db => $db}, ref($class) || $class;
}

sub push_results {
  my $Self = shift;
  my $tag = shift;
  foreach my $result (@_) {
    $result->[2] = $tag;
    push @{$Self->{results}}, $result;
    push @{$Self->{resultsbytag}{$tag}}, $result->[1]
      unless $result->[0] eq 'error';
  }
}

sub _parsepath {
  my $path = shift;
  my $item = shift;

  return $item unless $path =~ s{^/([^/]+)}{};
  # rfc6501
  my $selector = $1;
  $selector =~ s{~1}{/}g;
  $selector =~ s{~0}{~}g;

  if (ref($item) eq 'ARRAY') {
    if ($selector eq '*') {
      my @res;
      foreach my $one (@$item) {
	my $res =  _parsepath($path, $one);
        push @res, ref($res) eq 'ARRAY' ? @$res : $res;
      }
      return \@res;
    }
    if ($selector =~ m/^\d+$/) {
      return _parsepath($path, $item->[$selector]);
    }
  }
  if (ref($item) eq 'HASH') {
    return _parsepath($path, $item->{$selector});
  }

  return $item;
}

sub resolve_backref {
  my $Self = shift;
  my $tag = shift;
  my $path = shift;

  my $results = $Self->{resultsbytag}{$tag};
  die "No such result $tag" unless $results;

  my $res = _parsepath($path, @$results);

  $res = [$res] if (defined($res) and ref($res) ne 'ARRAY');
  return $res;
}

sub resolve_args {
  my $Self = shift;
  my $args = shift;
  my %res;
  foreach my $key (keys %$args) {
    if ($key =~ m/^\#(.*)/) {
      my $outkey = $1;
      my $res = eval { $Self->resolve_backref($args->{$key}{resultOf}, $args->{$key}{path}) };
      if ($@) {
        return (undef, { type => 'resultReference', message => $@ });
      }
      $res{$outkey} = $res;
    }
    else {
      $res{$key} = $args->{$key};
    }
  }
  return \%res;
}

sub handle_request {
  my $Self = shift;
  my $request = shift;

  delete $Self->{results};
  delete $Self->{resultsbytag};

  my $methods = $request->{methodCalls};

  foreach my $item (@$methods) {
    my ($command, $args, $tag) = @$item;
    my @items;
    my $can = $command;
    $can =~ s{/}{_};
    my $FuncRef = $Self->can("api_$can");
    warn "JMAP CMD $command";
    if ($FuncRef) {
      my ($myargs, $error) = $Self->resolve_args($args);
      if ($myargs) {
        @items = eval { $Self->$FuncRef($myargs, $tag) };
        if ($@) {
          @items = ['error', { type => "serverError", message => "$@" }];
          eval { $Self->rollback() };
        }
      }
      else {
        push @items, ['error', $error];
        next;
      }
    }
    else {
      @items = ['error', { type => 'unknownMethod' }];
    }
    $Self->push_results($tag, @items);
  }

  return {
    methodResponses => $Self->{results},
  };
}


sub setid {
  my $Self = shift;
  my $key = shift;
  my $val = shift;
  $Self->{idmap}{"#$key"} = $val;
}

sub idmap {
  my $Self = shift;
  my $key = shift;
  return unless $key;
  my $val = exists $Self->{idmap}{$key} ? $Self->{idmap}{$key} : $key;
  return $val;
}

sub getAccounts {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();

  my @list;
  push @list, {
    id => $Self->{db}->accountid(),
    name => $user->{displayname} || $user->{email},
    isPrimary => $JSON::true,
    versions => [ 0.20150115 ],
    extensions => {
      "io.jmap.proxy" => [ 1, 2 ],
    },
    capabilities => {
      maxSizeUpload => 1073741824,
    },
    mail => {
      isReadOnly => $JSON::false,
      maxSizeMessageAttachments => 1073741824,
      canDelaySend => $JSON::false,
      messageListSortOptions => [ "date", "id" ],
    },
    contacts => {
      isReadOnly => $JSON::false,
    },
    calendars => {
      isReadOnly => $JSON::false,
    },

    # legacy
    isReadOnly => $JSON::false,
    hasMail => $JSON::true,
    hasContacts => $JSON::true,
    hasCalendars => $JSON::true,
  };

  return ['accounts', {
    state => 'dummy',
    list => \@list,
  }];
}

sub refreshSyncedCalendars {
  my $Self = shift;

  $Self->{db}->sync_calendars();

  # no response
  return ();
}

sub api_UserPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

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

  return ['UserPreferences/get', { 
    accountId => $accountid,
    state => 'dummy',
    list => [{
      id => 'singleton',
      remoteServices => {},
      displayName => $user->{displayname} || $user->{email},
      language => 'en-us',
      timeZone => 'Australia/Melbourne',
      use24hClock => 'yes',
      theme => 'default',
      enableNewsletter => $JSON::true,
      defaultIdentifyId => 'id1',
      useDefaultFromOnSMTP => $JSON::false,
      excludeContactsFromBlacklist => $JSON::false,
    }],
  }];
}

sub api_ClientPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

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
#   i.e. the client will set the textOnly parameter to true when calling getMessageDetails.

  return ['ClientPreferences/get', {
    accountId => $accountid,
    state => 'dummy',
    list => [{
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
    }],
  }];
}

sub api_VacationResponse_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  return ['VacationReponse/get', {
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
  }];
}

sub _filter_list {
  my $list = shift;
  my $ids = shift;

  return $list unless $ids;

  my %map = map { $_ => 1 } @$ids;

  return [ grep { $map{$_->{id}} } @$list ];
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
  }];
}

sub begin {
  my $Self = shift;
  $Self->{db}->begin();
}

sub commit {
  my $Self = shift;
  $Self->{db}->commit();
}

sub _transError {
  my $Self = shift;
  if ($Self->{db}->in_transaction()) {
    $Self->{db}->rollback();
  }
  return @_;
}

sub api_Mailbox_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMailbox}";

  my $data = $dbh->selectall_arrayref("SELECT * FROM jmailboxes WHERE active = 1", {Slice => {}});

  my %ids;
  if ($args->{ids}) {
    %ids = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %ids = map { $_->{jmailboxid} => 1 } @$data;
  }

  my %byrole = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$data;

  my @list;

  my %ONLY_MAILBOXES;
  foreach my $item (@$data) {
    next unless delete $ids{$item->{jmailboxid}};
    $ONLY_MAILBOXES{$item->{jmailboxid}} = $item->{mustBeOnlyMailbox};

    my %rec = (
      id => "$item->{jmailboxid}",
      parentId => ($item->{parentId} ? "$item->{parentId}" : undef),
      name => Encode::decode_utf8($item->{name}),
      role => $item->{role},
      sortOrder => $item->{sortOrder},
      (map { $_ => ($item->{$_} ? $JSON::true : $JSON::false) } qw(mustBeOnlyMailbox mayReadItems mayAddItems mayRemoveItems mayCreateChild mayRename mayDelete)),
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    if (_prop_wanted($args, 'totalMessages')) {
      ($rec{totalMessages}) = $dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $item->{jmailboxid});
      $rec{totalMessages} += 0;
    }
    if (_prop_wanted($args, 'unreadMessages')) {
      ($rec{unreadMessages}) = $dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.isUnread = 1 AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $item->{jmailboxid});
      $rec{unreadMessages} += 0;
    }

    if (_prop_wanted($args, 'totalThreads')) {
      ($rec{totalThreads}) = $dbh->selectrow_array("SELECT COUNT(DISTINCT thrid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $item->{jmailboxid});
      $rec{totalThreads} += 0;
    }

    # for 'unreadThreads' we need to know threads with ANY unread messages,
    # so long as they aren't in an ONLY_MAILBOXES folder
    if (_prop_wanted($args, 'unreadThreads')) {
      my $folderlimit = '';
      if ($ONLY_MAILBOXES{$item->{jmailboxid}}) {
        $folderlimit = "AND jmessagemap.jmailboxid = " . $dbh->quote($item->{jmailboxid});
      } else {
        my @ids = grep { $ONLY_MAILBOXES{$_} } sort keys %ONLY_MAILBOXES;
        $folderlimit = "AND jmessagemap.jmailboxid NOT IN (" . join(',', map { $dbh->quote($_) } @ids) . ")" if @ids;
      }
      my $sql ="SELECT COUNT(DISTINCT thrid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1 AND thrid IN (SELECT thrid FROM jmessages JOIN jmessagemap USING (msgid) WHERE isUnread = 1 AND jmessages.active = 1 AND jmessagemap.active = 1 $folderlimit)";
      ($rec{unreadThreads}) = $dbh->selectrow_array($sql, {}, $item->{jmailboxid});
      $rec{unreadThreads} += 0;
    }

    push @list, \%rec;
  }
  my %missingids = %ids;

  $Self->commit();

  return ['Mailbox/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [map { "$_" } keys %missingids] : undef),
  }];
}

sub api_Mailbox_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMailbox}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $dbh->selectall_arrayref("SELECT * FROM jmailboxes WHERE jmodseq > ?1 OR jcountsmodseq > ?1", {Slice => {}}, $sinceState);

  my @changed;
  my @removed;
  my $onlyCounts = 1;
  foreach my $item (@$data) {
    if ($item->{active}) {
      push @changed, $item->{jmailboxid};
      $onlyCounts = 0 if $item->{jmodseq} > $sinceState;
    }
    else {
      push @removed, $item->{jmailboxid};
    }
  }

  $Self->commit();

  my @res = (['Mailbox/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
    changedProperties => $onlyCounts ? ["totalMessages", "unreadMessages", "totalThreads", "unreadThreads"] : JSON::null,
  }]);

  return @res;
}

sub _patchitem {
  my $target = shift;
  my $key = shift;
  my $value = shift;

  Carp::confess "missing patch target" unless ref($target) eq 'HASH';

  if ($key =~ s{^([^/]+)/}{}) {
    my $item = $1;
    $item =~ s{~1}{/}g;
    $item =~ s{~0}{~}g;
    return _patchitem($target->{$item}, $key, $value);
  }

  $key =~ s{~1}{/}g;
  $key =~ s{~0}{~}g;

  if (defined $value) {
    $target->{$key} = $value;
  }
  else {
    delete $target->{$key};
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

  $Self->{db}->begin_superlock();

  eval {
    # make sure our DB is up to date - happy to enforce this because folder names
    # are a unique namespace, so we should try to minimise the race time
    $Self->{db}->sync_folders();

    $Self->begin();
    my $user = $Self->{db}->get_user();
    $Self->commit();
    $oldState = "$user->{jstateMailbox}";

    ($created, $notCreated) = $Self->{db}->create_mailboxes($create);
    $Self->setid($_, $created->{$_}{id}) for keys %$created;
    $Self->_resolve_patch($update, 'api_Mailbox_get');
    ($updated, $notUpdated) = $Self->{db}->update_mailboxes($update, sub { $Self->idmap(shift) });
    ($destroyed, $notDestroyed) = $Self->{db}->destroy_mailboxes($destroy);

    $Self->begin();
    $user = $Self->{db}->get_user();
    $Self->commit();
    $newState = "$user->{jstateMailbox}";
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['Mailbox/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub _post_sort {
  my $Self = shift;
  my $data = shift;
  my $sortargs = shift; 
  my $storage = shift;

  my %fieldmap = (
    id => ['msgid', 0],
    receivedAt => ['internaldate', 1],
    sentAt => ['msgdate', 1],
    size => ['msgsize', 1],
    isunread => ['isUnread', 1],
    subject => ['sortsubject', 0],
    from => ['msgfrom', 0],
    to => ['msgto', 0],
  );

  my @res = sort {
    foreach my $arg (@$sortargs) {
      my $res = 0;
      my $field = $arg->{property};
      my $map = $fieldmap{$field};
      if ($map) {
        if ($map->[1]) {
	  $res = $a->{$map->[0]} <=> $b->{$map->[0]};
        }
        else {
          $res = $a->{$map->[0]} cmp $b->{$map->[0]};
        }
      }
      elsif ($field =~ m/^keyword:(.*)/) {
        my $keyword = $1;
	my $av = $a->{keywords}{$keyword} ? 1 : 0;
	my $bv = $b->{keywords}{$keyword} ? 1 : 0;
        $res = $av <=> $bv;
      }
      elsif ($field =~ m/^allThreadKeyword:(.*)/) {
        my $keyword = $1;
        $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
        my $av = ($storage->{hasthreadkeyword}{$a->{thrid}}{$keyword} || 0) == 2 ? 1 : 0;
        my $bv = ($storage->{hasthreadkeyword}{$b->{thrid}}{$keyword} || 0) == 2 ? 1 : 0;
        $res = $av <=> $bv;
      }
      elsif ($field =~ m/^someThreadKeyword:(.*)/) {
        my $keyword = $1;
        $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
        my $av = ($storage->{hasthreadkeyword}{$a->{thrid}}{$keyword} || 0) ? 1 : 0;
        my $bv = ($storage->{hasthreadkeyword}{$b->{thrid}}{$keyword} || 0) ? 1 : 0;
        $res = $av <=> $bv;
      }
      else {
        die "unknown field $field";
      }

      $res = -$res unless $arg->{isAscending};

      return $res if $res;
    }
    return $a->{msgid} cmp $b->{msgid}; # stable sort
  } @$data;

  return \@res;
}

sub _load_mailbox {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->{db}->dbh->selectall_arrayref("SELECT msgid,jmodseq,active FROM jmessagemap WHERE jmailboxid = ?", {}, $id);
  $Self->commit();
  return { map { $_->[0] => $_ } @$data };
}

sub _load_msgmap {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->{db}->dbh->selectall_arrayref("SELECT msgid,jmailboxid,jmodseq,active FROM jmessagemap");
  $Self->commit();
  my %map;
  foreach my $row (@$data) {
    $map{$row->[0]}{$row->[1]} = $row;
  }
  return \%map;
}

sub _load_hasatt {
  my $Self = shift;
  $Self->begin();
  my $data = $Self->{db}->dbh->selectcol_arrayref("SELECT msgid FROM jrawmessage WHERE hasAttachment = 1");
  $Self->commit();
  return { map { $_ => 1 } @$data };
}

sub _hasthreadkeyword {
  my $data = shift;
  my %res;
  foreach my $item (@$data) {
    next unless $item->{active};  # we get called by getMessageListUpdates, which includes inactive messages

    # have already seen a message for this thread
    if ($res{$item->{thrid}}) {
      foreach my $keyword (keys %{$item->{keywords}}) {
        # if not already known about, it wasn't present on previous messages, so it's a "some"
        $res{$item->{thrid}}{$keyword} ||= 1;
      }
      foreach my $keyword (keys %{$res{$item->{thrid}}}) {
        # if it was known already, but isn't on this one, it's a some
        $res{$item->{thrid}}{$keyword} = 1 unless $item->{keywords}{$keyword};
      }
    }

    # first message, it's "all" for every keyword
    else {
      $res{$item->{thrid}} = { map { $_ => 2 } keys %{$item->{keywords}} };
    }
  }
  return \%res;
}

sub _match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  return $Self->_match_operator($item, $condition, $storage) if $condition->{operator};

  if ($condition->{inMailbox}) {
    my $id = $Self->idmap($condition->{inMailbox});
    $storage->{mailbox}{$id} ||= $Self->_load_mailbox($id);
    return 0 unless $storage->{mailbox}{$id}{$item->{msgid}}[2]; #active
  }

  if ($condition->{inMailboxOtherThan}) {
    $storage->{msgmap} ||= $Self->_load_msgmap();
    my $cond = $condition->{inMailboxOtherThan};
    $cond = [$cond] unless ref($cond) eq 'ARRAY';  # spec and possible change
    my %match = map { $Self->idmap($_) => 1 } @$cond;
    my $data = $storage->{msgmap}{$item->{msgid}} || {};
    my $inany = 0;
    foreach my $id (keys %$data) {
      next if $match{$id};
      next unless $data->{$id}[3]; # isactive
      $inany = 1;
    }
    return 0 unless $inany;
  }

  if ($condition->{before}) {
    my $time = str2time($condition->{before});
    return 0 unless $item->{internaldate} < $time;
  }

  if ($condition->{after}) {
    my $time = str2time($condition->{after});
    return 0 unless $item->{internaldate} >= $time;
  }

  if ($condition->{minSize}) {
    return 0 unless $item->{msgsize} >= $condition->{minSize};
  }

  if ($condition->{maxSize}) {
    return 0 unless $item->{msgsize} < $condition->{maxSize};
  }

  # 2 == all
  # 1 == some
  # non-existent means none, of course
  if ($condition->{allInThreadHaveKeyword}) {
    # XXX case?
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{allInThreadHaveKeyword}};
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{allInThreadHaveKeyword}} == 2;
  }

  if ($condition->{someInThreadHaveKeyword}) {
    # XXX case?
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{someInThreadHaveKeyword}};
  }

  if ($condition->{noneInThreadHaveKeyword}) {
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 if $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{noneInThreadHaveKeyword}};
  }

  if ($condition->{hasKeyword}) {
    return 0 unless $item->{keywords}->{$condition->{hasKeyword}};
  }

  if ($condition->{notKeyword}) {
    return 0 if $item->{keywords}->{$condition->{notKeyword}};
  }

  if ($condition->{hasAttachment}) {
    $storage->{hasatt} ||= $Self->_load_hasatt();
    return 0 unless $storage->{hasatt}{$item->{msgid}};
    # XXX - hasAttachment
  }

  if ($condition->{text}) {
    $storage->{textsearch}{$condition->{text}} ||= $Self->{db}->imap_search('text', $condition->{text});
    return 0 unless $storage->{textsearch}{$condition->{text}}{$item->{msgid}};
  }

  if ($condition->{from}) {
    $storage->{fromsearch}{$condition->{from}} ||= $Self->{db}->imap_search('from', $condition->{from});
    return 0 unless $storage->{fromsearch}{$condition->{from}}{$item->{msgid}};
  }

  if ($condition->{to}) {
    $storage->{tosearch}{$condition->{to}} ||= $Self->{db}->imap_search('to', $condition->{to});
    return 0 unless $storage->{tosearch}{$condition->{to}}{$item->{msgid}};
  }

  if ($condition->{cc}) {
    $storage->{ccsearch}{$condition->{cc}} ||= $Self->{db}->imap_search('cc', $condition->{cc});
    return 0 unless $storage->{ccsearch}{$condition->{cc}}{$item->{msgid}};
  }

  if ($condition->{bcc}) {
    $storage->{bccsearch}{$condition->{bcc}} ||= $Self->{db}->imap_search('bcc', $condition->{bcc});
    return 0 unless $storage->{bccsearch}{$condition->{bcc}}{$item->{msgid}};
  }

  if ($condition->{subject}) {
    $storage->{subjectsearch}{$condition->{subject}} ||= $Self->{db}->imap_search('subject', $condition->{subject});
    return 0 unless $storage->{subjectsearch}{$condition->{subject}}{$item->{msgid}};
  }

  if ($condition->{body}) {
    $storage->{bodysearch}{$condition->{body}} ||= $Self->{db}->imap_search('body', $condition->{body});
    return 0 unless $storage->{bodysearch}{$condition->{body}}{$item->{msgid}};
  }

  if ($condition->{header}) {
    my $cond = $condition->{header};
    $cond->[1] = '' if @$cond == 1;
    $storage->{headersearch}{"@$cond"} ||= $Self->{db}->imap_search('header', @$cond);
    return 0 unless $storage->{headersearch}{"@$cond"}{$item->{msgid}};
  }

  return 1;
}

sub _match_operator {
  my $Self = shift;
  my ($item, $filter, $storage) = @_;
  if ($filter->{operator} eq 'NOT') {
    return not $Self->_match_operator($item, {operator => 'OR', conditions => $filter->{conditions}}, $storage);
  }
  elsif ($filter->{operator} eq 'OR') {
    foreach my $condition (@{$filter->{conditions}}) {
      return 1 if $Self->_match($item, $condition, $storage);
    }
    return 0;
  }
  elsif ($filter->{operator} eq 'AND') {
    foreach my $condition (@{$filter->{conditions}}) {
      return 0 if not $Self->_match($item, $condition, $storage);
    }
    return 1;
  }
  die "Invalid operator $filter->{operator}";
}

sub _messages_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  return [ grep { $Self->_match($_, $filter, $storage) } @$data ];
}

sub _collapse_messages {
  my $Self = shift;
  my ($data) = @_;
  my @res;
  my %seen;
  foreach my $item (@$data) {
    next if $seen{$item->{thrid}};
    push @res, $item;
    $seen{$item->{thrid}} = 1;
  }
  return \@res;
}

sub api_Email_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessage}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (exists $args->{position} and exists $args->{anchor});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (exists $args->{anchor} and not exists $args->{anchorOffset});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (not exists $args->{anchor} and exists $args->{anchorOffset});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}]) if $start < 0;

  my $data = $dbh->selectall_arrayref("SELECT * FROM jmessages WHERE active = 1", {Slice => {}});

  # commit before applying the filter, because it might call out for searches
  $Self->commit();

  map { $_->{keywords} = decode_json($_->{keywords} || {}) } @$data;
  my $storage = {data => $data};
  $data = $Self->_post_sort($data, $args->{sort}, $storage);
  $data = $Self->_messages_filter($data, $args->{filter}, $storage) if $args->{filter};
  $data = $Self->_collapse_messages($data) if $args->{collapseThreads};

  if ($args->{anchor}) {
    # need to calculate the position
    for (0..$#$data) {
      next unless $data->[$_]{msgid} eq $args->{anchor};
      $start = $_ + $args->{anchorOffset};
      $start = 0 if $start < 0;
      goto gotit;
    }
    return $Self->_transError(['error', {type => 'anchorNotFound'}]);
  }

gotit:

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{msgid} } $start..$end;

  my @res;
  push @res, ['Email/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    state => $newState,
    canCalculateUpdates => $JSON::true,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Email_queryChanges {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessage}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $data = $dbh->selectall_arrayref("SELECT * FROM jmessages", {Slice => {}});

  $Self->commit();

  map { $_->{keywords} = decode_json($_->{keywords} || {}) } @$data;
  my $storage = {data => $data};
  $data = $Self->_post_sort($data, $args->{sort}, $storage);

  # now we have the same sorted data set.  What we DON'T have is knowing that a message used to be in the filter,
  # but no longer is (aka isUnread).  There's no good way to do this :(  So we have to assume that every message
  # which is changed and NOT in the dataset used to be...

  # we also have to assume that it MIGHT have been the exemplar...

  my $tell = 1;
  my $total = 0;
  my $changes = 0;
  my @added;
  my @removed;
  # just do two entire logic paths, it's different enough to make it easier to write twice
  if ($args->{collapseThreads}) {
    # exemplar - only these messages are in the result set we're building
    my %exemplar;
    # finished - we've told about both the exemplar, and guaranteed to have told about all
    # the messages that could possibly have been the previous exemplar (at least one
    # non-deleted, unchanged message)
    my %finished;
    foreach my $item (@$data) {
      # we don't have to tell anything about finished threads, not even check them for membership in the search
      next if $finished{$item->{thrid}};

      # deleted is the same as not in filter for our purposes
      my $isin = $item->{active} ? ($args->{filter} ? $Self->_match($item, $args->{filter}, $storage) : 1) : 0;

      # only exemplars count for the total - we need to know total even if not telling any more
      if ($isin and not $exemplar{$item->{thrid}}) {
        $total++;
        $exemplar{$item->{thrid}} = $item->{msgid};
      }
      next unless $tell;

      # jmodseq greater than sinceState is a change
      my $changed = ($item->{jmodseq} > $args->{sinceState});
      my $isnew = ($item->{jcreated} > $args->{sinceState});

      if ($changed) {
        # if it's in AND it's the exemplar, it's been added
        if ($isin and $exemplar{$item->{thrid}} eq $item->{msgid}) {
          push @added, {id => "$item->{msgid}", index => $total-1};
          push @removed, "$item->{msgid}";
          $changes++;
        }
        # otherwise it's removed
        else {
          push @removed, "$item->{msgid}";
          $changes++;
        }
      }
      # unchanged and isin, final candidate for old exemplar!
      elsif ($isin) {
        # remove it unless it's also the current exemplar
        if ($exemplar{$item->{thrid}} ne $item->{msgid}) {
          push @removed, "$item->{msgid}";
          $changes++;
        }
        # and we're done
        $finished{$item->{thrid}} = 1;
      }

      if ($args->{maxChanges} and $changes > $args->{maxChanges}) {
        return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
      }

      if ($args->{upToMessageId} and $args->{upToMessageId} eq $item->{msgid}) {
        # stop mentioning changes
        $tell = 0;
      }
    }
  }

  # non-collapsed case
  else {
    foreach my $item (@$data) {
      # deleted is the same as not in filter for our purposes
      my $isin = $item->{active} ? ($args->{filter} ? $Self->_match($item, $args->{filter}, $storage) : 1) : 0;

      # all active messages count for the total
      $total++ if $isin;
      next unless $tell;

      # jmodseq greater than sinceState is a change
      my $changed = ($item->{jmodseq} > $args->{sinceState});
      my $isnew = ($item->{jcreated} > $args->{sinceState});

      if ($changed) {
        if ($isin) {
          push @added, {id => "$item->{msgid}", index => $total-1};
          push @removed, "$item->{msgid}";
          $changes++;
        }
        else {
          push @removed, "$item->{msgid}";
          $changes++;
        }
      }

      if ($args->{maxChanges} and $changes > $args->{maxChanges}) {
        return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
      }

      if ($args->{upToMessageId} and $args->{upToMessageId} eq $item->{msgid}) {
        # stop mentioning changes
        $tell = 0;
      }
    }
  }

  my @res;
  push @res, ['Email/queryChanges', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    oldState => "$args->{sinceState}",
    newState => $newState,
    removed => \@removed,
    added => \@added,
    total => $total,
  }];

  return @res;
}

sub _extract_terms {
  my $filter = shift;
  return () unless $filter;
  my @list;
  push @list, _extract_terms($filter->{conditions});
  push @list, $filter->{body} if $filter->{body};
  push @list, $filter->{text} if $filter->{text};
  push @list, $filter->{subject} if $filter->{subject};
  return @list;
}

sub SearchSnippet_get {
  my $Self = shift;
  my $args = shift;

  my $messages = $Self->api_Email_get({
    accountId => $args->{accountId},
    ids => $args->{emailIds},
    properties => ['subject', 'textBody', 'preview'],
  });

  return $messages unless $messages->[0] eq 'Email/get';
  $messages->[0] = 'SearchSnippet/get';
  delete $messages->[1]{state};
  $messages->[1]{filter} = $args->{filter};
  $messages->[1]{collapseThreads} = $args->{collapseThreads}, # work around client bug

  my @terms = _extract_terms($args->{filter});
  my $str = join("|", @terms);
  my $tag = 'mark';
  foreach my $item (@{$messages->[1]{list}}) {
    $item->{emailId} = delete $item->{id};
    my $text = delete $item->{textBody};
    $item->{subject} = escape_html($item->{subject});
    $item->{preview} = escape_html($item->{preview});
    next unless @terms;
    $item->{subject} =~ s{\b($str)\b}{<$tag>$1</$tag>}gsi;
    if ($text =~ m{(.{0,20}\b(?:$str)\b.*)}gsi) {
      $item->{preview} = substr($1, 0, 200);
      $item->{preview} =~ s{^\s+}{}gs;
      $item->{preview} =~ s{\s+$}{}gs;
      $item->{preview} =~ s{[\r\n]+}{ -- }gs;
      $item->{preview} =~ s{\s+}{ }gs;
      $item->{preview} = escape_html($item->{preview});
      $item->{preview} =~ s{\b($str)\b}{<$tag>$1</$tag>}gsi;
    }
    $item->{body} = $item->{preview}; # work around client bug
  }

  return $messages;
}

sub api_Email_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessage}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  # XXX - lots to do about properties here
  my %seenids;
  my %missingids;
  my @list;
  my $need_content = 0;
  foreach my $prop (qw(hasAttachment headers preview textBody htmlBody attachments attachedMessages)) {
    $need_content = 1 if _prop_wanted($args, $prop);
  }
  $need_content = 1 if ($args->{properties} and grep { m/^headers\./ } @{$args->{properties}});
  my %msgidmap;
  foreach my $msgid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$msgid};
    $seenids{$msgid} = 1;
    my $data = $dbh->selectrow_hashref("SELECT * FROM jmessages WHERE msgid = ?", {}, $msgid);
    unless ($data) {
      $missingids{$msgid} = 1;
      next;
    }

    $msgidmap{$msgid} = $data->{msgid};
    my $item = {
      id => "$msgid",
    };

    if (_prop_wanted($args, 'threadId')) {
      $item->{threadId} = "$data->{thrid}";
    }

    if (_prop_wanted($args, 'mailboxIds')) {
      my $ids = $dbh->selectcol_arrayref("SELECT jmailboxid FROM jmessagemap WHERE msgid = ? AND active = 1", {}, $msgid);
      $item->{mailboxIds} = {map { $_ => $JSON::true } @$ids};
    }

    if (_prop_wanted($args, 'inReplyToMessageId')) {
      $item->{inReplyToMessageId} = $data->{msginreplyto};
    }

    if (_prop_wanted($args, 'hasAttachment')) {
      $item->{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
    }

    if (_prop_wanted($args, 'keywords')) {
      $item->{keywords} = decode_json($data->{keywords});
    }

    foreach my $email (qw(to cc bcc from replyTo)) {
      if (_prop_wanted($args, $email)) {
        my $val;
        my @addrs = $Self->{db}->parse_emails($data->{"msg$email"});
        $item->{$email} = \@addrs;
      }
    }

    if (_prop_wanted($args, 'subject')) {
      $item->{subject} = Encode::decode_utf8($data->{msgsubject});
    }

    if (_prop_wanted($args, 'sentAt')) {
      $item->{sentAt} = $Self->{db}->isodate($data->{msgdate});
    }

    if (_prop_wanted($args, 'receivedAt')) {
      $item->{receivedAt} = $Self->{db}->isodate($data->{internaldate});
    }

    if (_prop_wanted($args, 'size')) {
      $item->{size} = $data->{msgsize};
    }

    if (_prop_wanted($args, 'blobId')) {
      $item->{blobId} = "m-$msgid";
    }

    push @list, $item;
  }

  $Self->commit();

  # need to load messages from the server
  if ($need_content) {
    my $content = $Self->{db}->fill_messages(map { $_->{id} } @list);
    foreach my $item (@list) {
      my $data = $content->{$item->{id}};
      foreach my $prop (qw(preview textBody htmlBody)) {
        if (_prop_wanted($args, $prop)) {
          $item->{$prop} = $data->{$prop};
        }
      }
      if (_prop_wanted($args, 'body')) {
        if ($data->{htmlBody}) {
          $item->{htmlBody} = $data->{htmlBody};
        }
        else {
          $item->{textBody} = $data->{textBody};
        }
      }
      if (exists $item->{textBody} and not $item->{textBody}) {
        $item->{textBody} = JMAP::DB::htmltotext($data->{htmlBody});
      }
      if (_prop_wanted($args, 'hasAttachment')) {
        $item->{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
      }
      if (_prop_wanted($args, 'headers')) {
        $item->{headers} = $data->{headers};
      }
      elsif ($args->{properties}) {
        my %wanted;
        foreach my $prop (@{$args->{properties}}) {
          next unless $prop =~ m/^headers\.(.*)/;
          $item->{headers} ||= {}; # avoid zero matched headers bug
          $wanted{lc $1} = 1;
        }
        foreach my $key (keys %{$data->{headers}}) {
          next unless $wanted{lc $key};
          $item->{headers}{lc $key} = $data->{headers}{$key};
        }
      }
      if (_prop_wanted($args, 'attachments')) {
        $item->{attachments} = $data->{attachments};
      }
      if (_prop_wanted($args, 'attachedMessages')) {
        $item->{attachedMessages} = $data->{attachedMessages};
      }
    }
  }

  return ['Email/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [keys %missingids] : undef),
  }];
}

# NOT AN API CALL as such...
sub getRawMessage {
  my $Self = shift;
  my $selector = shift;

  my $msgid = $selector;
  return () unless $msgid =~ s/^([mf])-//;
  my $source = $1;
  my $part;
  my $filename;
  if ($msgid =~ s{/(.*)}{}) {
    $filename = $1;
  }
  if ($msgid =~ s{-(.*)}{}) {
   $part = $1;
  }

  my ($type, $data);
  if ($source eq 'f') {
    ($type, $data) = $Self->{db}->get_file($msgid);
  }
  else {
    ($type, $data) = $Self->{db}->get_raw_message($msgid, $part);
  }

  return ($type, $data, $filename);
}

# or this
sub uploadFile {
  my $Self = shift;
  my ($accountid, $type, $content) = @_; # XXX filehandle?

  return $Self->{db}->put_file($accountid, $type, $content);
}

sub downloadFile {
  my $Self = shift;
  my $jfileid = shift;

  my ($type, $content) = $Self->{db}->get_file($jfileid);

  return ($type, $content);
}

sub api_Email_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessage}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT msgid,active FROM jmessages WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  my @changed;
  my @removed;

  foreach my $row (@$data) {
    if ($row->[1]) {
      push @changed, $row->[0];
    }
    else {
      push @removed, $row->[0];
    }
  }

  $Self->commit();

  my @res;
  push @res, ['Email/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_Email_set {
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

  $Self->{db}->begin_superlock();

  eval {
    # get state up-to-date first
    $Self->{db}->sync_imap();

    $Self->begin();
    my $user = $Self->{db}->get_user();
    $Self->commit();
    $oldState = "$user->{jstateMessage}";

    ($created, $notCreated) = $Self->{db}->create_messages($create, sub { $Self->idmap(shift) });
    $Self->setid($_, $created->{$_}{id}) for keys %$created;
    $Self->_resolve_patch($update, 'api_Email_get');
    ($updated, $notUpdated) = $Self->{db}->update_messages($update, sub { $Self->idmap(shift) });
    ($destroyed, $notDestroyed) = $Self->{db}->destroy_messages($destroy);

    # XXX - cheap dumb racy version
    $Self->{db}->sync_imap();

    $Self->begin();
    $user = $Self->{db}->get_user();
    $Self->commit();
    $newState = "$user->{jstateMessage}";
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  foreach my $cid (sort keys %$created) {
    my $msgid = $created->{$cid}{id};
    $created->{$cid}{blobId} = "m-$msgid";
  }

  my @res;
  push @res, ['Email/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_Email_import {
  my $Self = shift;
  my $args = shift;

  my %created;
  my %notcreated;

  $Self->{db}->begin_superlock();

  # make sure our DB is up to date
  $Self->{db}->sync_folders();

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (not $args->{messages} or ref($args->{messages}) ne 'HASH');

  my $dbh = $Self->{db}->dbh();
  my $mailboxdata = $dbh->selectall_arrayref("SELECT * FROM jmailboxes WHERE active = 1", {Slice => {}});
  my %validids = map { $_->{jmailboxid} => 1 } @$mailboxdata;

  foreach my $id (keys %{$args->{messages}}) {
    my $message = $args->{messages}{$id};
    # sanity check
    return $Self->_transError(['error', {type => 'invalidArguments'}])
      if (not $message->{mailboxIds} or ref($message->{mailboxIds}) ne 'HASH');
    return $Self->_transError(['error', {type => 'invalidArguments'}])
      if (not $message->{blobId});
  }

  $Self->commit();

  my %todo;
  foreach my $id (keys %{$args->{messages}}) {
    my $message = $args->{messages}{$id};
    my @ids = map { $Self->idmap($_) } keys %{$message->{mailboxIds}};
    if (grep { not $validids{$_} } @ids) {
      $notcreated{$id} = { type => 'invalidMailboxes' };
      next;
    }

    my ($type, $file) = $Self->{db}->get_file($message->{blobId});
    unless ($file) {
      $notcreated{$id} = { type => 'notFound' };
      next;
    }

    unless ($type eq 'message/rfc822') {
      $notcreated{$id} = { type => 'notFound', description => "incorrect type $type for $message->{blobId}" };
      next;
    }

    my ($msgid, $thrid, $size) = eval { $Self->{db}->import_message($file, \@ids, $message->{keywords}) };
    if ($@) {
      $notcreated{$id} = { type => 'internalError', description => $@ };
      next;
    }

    $created{$id} = {
      id => $msgid,
      blobId => $message->{blobId},
      threadId => $thrid,
      size => $size,
    };
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['Email/import', {
    accountId => $accountid,
    created => \%created,
    notCreated => \%notcreated,
  }];

  return @res;
}

sub api_Email_copy {
  my $Self = shift;
  return $Self->_transError(['error', {type => 'notImplemented'}]);
}

sub reportMessages {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{emailIds};

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not exists $args->{asSpam};

  $Self->commit();

  my @ids = map { $Self->idmap($_) } @{$args->{emailIds}};
  my ($reported, $notfound) = $Self->report_messages(\@ids, $args->{asSpam});

  my @res;
  push @res, ['messagesReported', {
    accountId => $Self->{db}->accountid(),
    asSpam => $args->{asSpam},
    reported => $reported,
    notFound => $notfound,
  }];

  return @res;
}

sub api_Thread_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateThread}";

  # XXX - error if no IDs

  my @list;
  my %seenids;
  my %missingids;
  my @allmsgs;
  foreach my $thrid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$thrid};
    $seenids{$thrid} = 1;
    my $data = $dbh->selectall_arrayref("SELECT * FROM jmessages WHERE thrid = ? AND active = 1 ORDER BY internaldate", {Slice => {}}, $thrid);
    unless (@$data) {
      $missingids{$thrid} = 1;
      next;
    }
    my %drafts;
    my @msgs;
    my %seenmsgs;
    foreach my $item (@$data) {
      next unless $item->{isDraft};
      next unless $item->{msginreplyto};  # push the rest of the drafts to the end
      push @{$drafts{$item->{msginreplyto}}}, $item->{msgid};
    }
    foreach my $item (@$data) {
      next if $item->{isDraft};
      push @msgs, $item->{msgid};
      $seenmsgs{$item->{msgid}} = 1;
      next unless $item->{msgmessageid};
      if (my $draftmsgs = $drafts{$item->{msgmessageid}}) {
        push @msgs, @$draftmsgs;
        $seenmsgs{$_} = 1 for @$draftmsgs;
      }
    }
    # make sure unlinked drafts aren't forgotten!
    foreach my $item (@$data) {
      next if $seenmsgs{$item->{msgid}};
      push @msgs, $item->{msgid};
      $seenmsgs{$item->{msgid}} = 1;
    }
    push @list, {
      id => "$thrid",
      emailIds => [map { "$_" } @msgs],
    };
    push @allmsgs, @msgs;
  }

  $Self->commit();

  my @res;
  push @res, ['Thread/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [keys %missingids] : undef),
  }];

  return @res;
}

sub api_Thread_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateThread}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT * FROM jmessages WHERE jmodseq > ?";

  if ($args->{maxChanges}) {
    $sql .= " LIMIT " . (int($args->{maxChanges}) + 1);
  }

  my $data = $dbh->selectall_arrayref($sql, {Slice => {}}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  my %threads;
  my %delcheck;
  foreach my $row (@$data) {
    $threads{$row->{thrid}} = 1;
    $delcheck{$row->{thrid}} = 1 unless $row->{active};
  }

  my @removed;
  foreach my $key (keys %delcheck) {
    my ($exists) = $dbh->selectrow_array("SELECT COUNT(DISTINCT jmessages.msgid) FROM jmessages JOIN jmessagemap WHERE thrid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $key);
    unless ($exists) {
      delete $threads{$key};
      push @removed, $key;
    }
  }

  my @changed = keys %threads;

  $Self->commit();

  my @res;
  push @res, ['Thread_changes', {
    accountId => $accountid,
    oldState => $args->{sinceState},
    newState => $newState,
    changed => \@changed,
    removed => \@removed,
  }];

  return @res;
}

sub _prop_wanted {
  my $args = shift;
  my $prop = shift;
  return 1 if $prop eq 'id'; # MUST ALWAYS RETURN id
  return 1 unless $args->{properties};
  return 1 if grep { $_ eq $prop } @{$args->{properties}};
  return 0;
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

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendar}";

  my $data = $dbh->selectall_arrayref("SELECT jcalendarid, name, color, isVisible, mayReadFreeBusy, mayReadItems, mayAddItems, mayModifyItems, mayRemoveItems, mayDelete, mayRename FROM jcalendars WHERE active = 1");

  my %ids;
  if ($args->{ids}) {
    %ids = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %ids = map { $_->[0] => 1 } @$data;
  }

  my @list;

  foreach my $item (@$data) {
    next unless delete $ids{$item->[0]};

    my %rec = (
      id => "$item->[0]",
      name => $item->[1],
      color => $item->[2],
      isVisible => $item->[3] ? $JSON::true : $JSON::false,
      mayReadFreeBusy => $item->[4] ? $JSON::true : $JSON::false,
      mayReadItems => $item->[5] ? $JSON::true : $JSON::false,
      mayAddItems => $item->[6] ? $JSON::true : $JSON::false,
      mayModifyItems => $item->[7] ? $JSON::true : $JSON::false,
      mayRemoveItems => $item->[8] ? $JSON::true : $JSON::false,
      mayDelete => $item->[9] ? $JSON::true : $JSON::false,
      mayRename => $item->[10] ? $JSON::true : $JSON::false,
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }
  my %missingids = %ids;

  $Self->commit();

  return ['Calendar/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [map { "$_" } keys %missingids] : undef),
  }];
}

sub api_Calendar_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendar}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $dbh->selectall_arrayref("SELECT jcalendarid, jmodseq, active FROM jcalendars ORDER BY jcalendarid");

  my @changed;
  my @removed;
  my $onlyCounts = 1;
  foreach my $item (@$data) {
    if ($item->[1] > $sinceState) {
      if ($item->[3]) {
        push @changed, $item->[0];
        $onlyCounts = 0;
      }
      else {
        push @removed, $item->[0];
      }
    }
    elsif (($item->[2] || 0) > $sinceState) {
      if ($item->[3]) {
        push @changed, $item->[0];
      }
      else {
        push @removed, $item->[0];
      }
    }
  }

  $Self->commit();

  my @res = (['Calendar/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }]);

  return @res;
}

sub _event_match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  # XXX - condition handling code
  if ($condition->{inCalendars}) {
    my $match = 0;
    foreach my $id (@{$condition->{inCalendars}}) {
      next unless $item->[1] eq $id;
      $match = 1;
    }
    return 0 unless $match;
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

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendarEvent}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $data = $dbh->selectall_arrayref("SELECT eventuid,jcalendarid FROM jevents WHERE active = 1 ORDER BY eventuid");

  $data = $Self->_event_filter($data, $args->{filter}, {}) if $args->{filter};

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_][0] } $start..$end;

  $Self->commit();

  my @res;
  push @res, ['CalendarEvent/query', {
    accountId => $accountid,
    filter => $args->{filter},
    state => $newState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_CalendarEvent_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendarEvent}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  my %seenids;
  my %missingids;
  my @list;
  foreach my $eventid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$eventid};
    $seenids{$eventid} = 1;
    my $data = $dbh->selectrow_hashref("SELECT * FROM jevents WHERE eventuid = ?", {}, $eventid);
    unless ($data) {
      $missingids{$eventid} = 1;
      next;
    }

    my $item = decode_json($data->{payload});

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $eventid;
    $item->{calendarId} = "$data->{jcalendarid}" if _prop_wanted($args, "calendarId");

    push @list, $item;
  }

  $Self->commit();

  return ['CalendarEvent/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [keys %missingids] : undef),
  }];
}

sub api_CalendarEvent_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendarEvent}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT eventuid,active FROM jevents WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @changed;
  my @removed;

  foreach my $row (@$data) {
    if ($row->[1]) {
      push @changed, $row->[0];
    }
    else {
      push @removed, $row->[0];
    }
  }

  my @res;
  push @res, ['CalendarEvent/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_Addressbook_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  # we have no datatype for this yet
  my $newState = "$user->{jhighestmodseq}";

  my $data = $dbh->selectall_arrayref("SELECT jaddressbookid, name, isVisible, mayReadItems, mayAddItems, mayModifyItems, mayRemoveItems, mayDelete, mayRename FROM jaddressbooks WHERE active = 1");

  my %ids;
  if ($args->{ids}) {
    %ids = map { $Self->($_) => 1 } @{$args->{ids}};
  }
  else {
    %ids = map { $_->[0] => 1 } @$data;
  }

  my @list;

  foreach my $item (@$data) {
    next unless delete $ids{$item->[0]};

    my %rec = (
      id => "$item->[0]",
      name => $item->[1],
      isVisible => $item->[2] ? $JSON::true : $JSON::false,
      mayReadItems => $item->[3] ? $JSON::true : $JSON::false,
      mayAddItems => $item->[4] ? $JSON::true : $JSON::false,
      mayModifyItems => $item->[5] ? $JSON::true : $JSON::false,
      mayRemoveItems => $item->[6] ? $JSON::true : $JSON::false,
      mayDelete => $item->[7] ? $JSON::true : $JSON::false,
      mayRename => $item->[8] ? $JSON::true : $JSON::false,
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }
  my %missingids = %ids;

  $Self->commit();

  return ['Addressbook/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [map { "$_" } keys %missingids] : undef),
  }];
}

sub api_Addressbook_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  # we have no datatype for you yet
  my $newState = "$user->{jhighestmodseq}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $dbh->selectall_arrayref("SELECT jaddressbookid, jmodseq, active FROM jaddressbooks ORDER BY jaddressbookid");

  my @changed;
  my @removed;
  my $onlyCounts = 1;
  foreach my $item (@$data) {
    if ($item->[1] > $sinceState) {
      if ($item->[3]) {
        push @changed, $item->[0];
        $onlyCounts = 0;
      }
      else {
        push @removed, $item->[0];
      }
    }
    elsif (($item->[2] || 0) > $sinceState) {
      if ($item->[3]) {
        push @changed, $item->[0];
      }
      else {
        push @removed, $item->[0];
      }
    }
  }

  $Self->commit();

  my @res = (['Addressbook/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }]);

  return @res;
}

sub _contact_match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  # XXX - condition handling code
  if ($condition->{inAddressbooks}) {
    my $match = 0;
    foreach my $id (@{$condition->{inAddressbooks}}) {
      next unless $item->[1] eq $id;
      $match = 1;
    }
    return 0 unless $match;
  }

  return 1;
}

sub _contact_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  my @res;
  foreach my $item (@$data) {
    next unless $Self->_contact_match($item, $filter, $storage);
    push @res, $item;
  }
  return \@res;
}

sub api_Contact_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContact}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $data = $dbh->selectall_arrayref("SELECT contactuid,jaddressbookid FROM jcontacts WHERE active = 1 ORDER BY contactuid");

  $data = $Self->_event_filter($data, $args->{filter}, {}) if $args->{filter};

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_][0] } $start..$end;

  $Self->commit();

  my @res;
  push @res, ['Contact/query', {
    accountId => $accountid,
    filter => $args->{filter},
    state => $newState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Contact_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContact}";

  #properties: String[] A list of properties to fetch for each message.

  my $data = $dbh->selectall_hashref("SELECT * FROM jcontacts WHERE active = 1", 'contactuid', {Slice => {}});

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

    my $item = decode_json($data->{$id}{payload});

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $id;

    push @list, $item;
  }
  $Self->commit();

  return ['Contact/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%want ? [keys %want] : undef),
  }];
}

sub api_Contact_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContact}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT contactuid,active FROM jcontacts WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }
  $Self->commit();

  my @changed;
  my @removed;

  foreach my $row (@$data) {
    if ($row->[1]) {
      push @changed, $row->[0];
    }
    else {
      push @removed, $row->[0];
    }
  }

  my @res;
  push @res, ['Contact/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_ContactGroup_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContactGroup}";

  #properties: String[] A list of properties to fetch for each message.

  my $data = $dbh->selectall_hashref("SELECT * FROM jcontactgroups WHERE active = 1", 'groupuid', {Slice => {}});

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

    my $item = {};
    $item->{id} = $id;

    if (_prop_wanted($args, 'name')) {
      $item->{name} = $data->{$id}{name};
    }

    if (_prop_wanted($args, 'contactIds')) {
      my $ids = $dbh->selectcol_arrayref("SELECT contactuid FROM jcontactgroupmap WHERE groupuid = ?", {}, $id);
      $item->{contactIds} = $ids;
    }

    push @list, $item;
  }
  $Self->commit();

  return ['ContactGroup/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%want ? [keys %want] : undef),
  }];
}

sub api_ContactGroup_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContactGroup}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT groupuid,active FROM jcontactgroups WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  my @changed;
  my @removed;

  foreach my $row (@$data) {
    if ($row->[1]) {
      push @changed, $row->[0];
    }
    else {
      push @removed, $row->[0];
    }
  }
  $Self->commit();

  my @res;
  push @res, ['ContactGroup/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_ContactGroup_set {
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

  $Self->{db}->begin_superlock();

  eval {
    $Self->{db}->sync_addressbooks();

    $Self->begin();
    my $user = $Self->{db}->get_user();
    $oldState = "$user->{jstateContactGroup}";
    $Self->commit();

    ($created, $notCreated) = $Self->{db}->create_contact_groups($create);
    $Self->setid($_, $created->{$_}{id}) for keys %$created;
    $Self->_resolve_patch($update, 'api_ContactGroup_get');
    ($updated, $notUpdated) = $Self->{db}->update_contact_groups($update, sub { $Self->idmap(shift) });
    ($destroyed, $notDestroyed) = $Self->{db}->destroy_contact_groups($destroy);

    # XXX - cheap dumb racy version
    $Self->{db}->sync_addressbooks();

    $Self->begin();
    $user = $Self->{db}->get_user();
    $newState = "$user->{jstateContactGroup}";
    $Self->commit();
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['ContactGroup/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_Contact_set {
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

  $Self->{db}->begin_superlock();

  eval {
    $Self->{db}->sync_addressbooks();

    $Self->begin();
    my $user = $Self->{db}->get_user();
    $oldState = "$user->{jstateContact}";
    $Self->commit();

    ($created, $notCreated) = $Self->{db}->create_contacts($create);
    $Self->setid($_, $created->{$_}{id}) for keys %$created;
    $Self->_resolve_patch($update, 'api_Contact_get');
    ($updated, $notUpdated) = $Self->{db}->update_contacts($update, sub { $Self->idmap(shift) });
    ($destroyed, $notDestroyed) = $Self->{db}->destroy_contacts($destroy);

    # XXX - cheap dumb racy version
    $Self->{db}->sync_addressbooks();

    $Self->begin();
    $user = $Self->{db}->get_user();
    $newState = "$user->{jstateContact}";
    $Self->commit();
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['Contact/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
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

  $Self->{db}->begin_superlock();

  eval {
    $Self->{db}->sync_calendars();

    $Self->begin();
    my $user = $Self->{db}->get_user();
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
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['CalendarEvent/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

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

  $Self->{db}->begin_superlock();

  eval {
    $Self->{db}->sync_calendars();

    $Self->begin();
    my $user = $Self->{db}->get_user();
    $oldState = "$user->{jstateCalendar}";
    $Self->commit();

    ($created, $notCreated) = $Self->{db}->create_calendars($create);
    $Self->setid($_, $created->{$_}{id}) for keys %$created;
    $Self->_resolve_patch($update, 'api_Calendar_get');
    ($updated, $notUpdated) = $Self->{db}->update_calendars($update, sub { $Self->idmap(shift) });
    ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendars($destroy);

    # XXX - cheap dumb racy version
    $Self->{db}->sync_calendars();

    $Self->begin();
    $user = $Self->{db}->get_user();
    $newState = "$user->{jstateCalendar}";
    $Self->commit();
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['Calendar/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

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
  push @res, 'subid asc';
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

sub api_MessageSubmission_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessageSubmission}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $sort = _mk_submission_sort($args->{sort});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $sort;

  my $data = $dbh->selectall_arrayref("SELECT subid,thrid,msgid,sendat FROM jsubmission WHERE active = 1 ORDER BY $sort");

  $data = $Self->_submission_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar(@$data);

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @list = map { $data->[$_] } $start..$end;

  $Self->commit();

  my @res;

  my $subids = [ map { "$_->[0]" } @list ];
  push @res, ['MessageSubmission/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    state => $newState,
    canCalculateUpdates => $JSON::true,
    position => $start,
    total => $total,
    ids => $subids,
  }];

  return @res;
}

sub api_MessageSubmission_queryChanges {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessageSubmission}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  #properties: String[] A list of properties to fetch for each message.

  my $sort = _mk_submission_sort($args->{sort});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $sort;

  my $data = $dbh->selectall_arrayref("SELECT subid,thrid,msgid,sendat,jmodseq,active FROM jsubmission ORDER BY $sort");

  $data = $Self->_submission_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar(@$data);

  $Self->commit();

  my @added;
  my @removed;

  my $index = 0;
  foreach my $item (@$data) {
    if ($item->[4] <= $sinceState) {
      $index++ if $item->[5];
      next;
    }
    # changed
    push @removed, "$item->[0]";
    next unless $item->[5];
    push @added, { id => "$item->[0]", index => $index };
    $index++;
  }

  return ['MessageSubmission/queryChanges', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    oldState => $sinceState,
    newState => $newState,
    total => $total,
    removed => \@removed,
    added => \@added,
  }];
}

sub api_MessageSubmission_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessageSubmission}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  my %seenids;
  my %missingids;
  my @list;
  foreach my $subid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$subid};
    $seenids{$subid} = 1;
    my $data = $dbh->selectrow_hashref("SELECT * FROM jsubmission WHERE jsubid = ?", {}, $subid);
    unless ($data) {
      $missingids{$subid} = 1;
      next;
    }

    my ($thrid) = $dbh->selectrow_array("SELECT thrid FROM jmessages WHERE msgid = ?", {}, $data->{msgid});

    my $item = {
      id => $subid,
      identityId => $data->{identity},
      emailId => $data->{msgid},
      threadId => $data->{thrid},
      envelope => $data->{envelope} ? decode_json($data->{envelope}) : undef,
      sendAt => scalar($Self->{db}->isodate($data->{sendat})),
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

  return ['MessageSubmission/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => (%missingids ? [keys %missingids] : undef),
  }];
}

sub api_MessageSubmission_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMessageSubmission}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $dbh->selectall_arrayref("SELECT subid,thrid,msgid,sendat,jmodseq,active FROM jsubmission WHERE jmodseq > ? ORDER BY jmodseq ASC", {}, $sinceState);

  $Self->commit();

  my $hasMore = 0;
  if ($args->{maxChanges} and $#$data >= $args->{maxChanges}) {
    $#$data = $args->{maxChanges} - 1;
    $newState = "$data->[-1][4]";
    $hasMore = 1;
  }

  my @changed;
  my @removed;

  foreach my $item (@$data) {
    # changed
    if ($item->[5]) {
      push @changed, "$item->[0]";
    }
    else {
      push @removed, "$item->[0]";
    }
  }

  my @res;
  push @res, ['MessageSubmission/changes', {
    accountId => $accountid,
    oldState => $sinceState,
    newState => $newState,
    hasMoreUpdates => $hasMore ? $JSON::true : $JSON::false,
    changed => \@changed,
    removed => \@removed,
  }];

  return @res;
}

sub api_MessageSubmission_set {
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
  my $toUpdate = $args->{onSuccessUpdateMessage} || {};
  my $toDestroy = $args->{onSuccessDestroyMessage} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  # TODO: need to support ifInState for this sucker

  my %updateMessages;
  my @destroyMessages;

  $Self->{db}->begin_superlock();

  eval {
    # make sure our DB is up to date
    $Self->{db}->sync_folders();

    $Self->{db}->begin();
    my $user = $Self->{db}->get_user();
    $oldState = "$user->{jstateMessageSubmission}";
    $Self->{db}->commit();

    ($created, $notCreated) = $Self->{db}->create_submissions($create, sub { $Self->idmap(shift) });
    $Self->setid($_, $created->{$_}{id}) for keys %$created;
    $Self->_resolve_patch($update, 'api_MessageSubmission_get');
    ($updated, $notUpdated) = $Self->{db}->update_submissions($update, sub { $Self->idmap(shift) });

    my @possible = ((map { $_->{id} } values %$created), (keys %$updated), @$destroy);

    # we need to convert all the IDs that were successfully created and updated plus any POSSIBLE
    # one that might be deleted into a map from id to messageid - after create and update, but
    # before delete.
    my $result = $Self->getMessageSubmissions({ids => \@possible, properties => ['emailId']});
    my %emailIds;
    if ($result->[0] eq 'messageSubmissions') {
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
      $updateMessages{$emailIds{$id}} = $toUpdate->{$key};
    }
    foreach my $key (@$toDestroy) {
      my $id = $Self->idmap($key);
      next unless $allowed{$id};
      push @destroyMessages, $emailIds{$id};
    }

    $Self->{db}->begin();
    $user = $Self->{db}->get_user();
    $newState = "$user->{jstateMessageSubmission}";
    $Self->{db}->commit();
  };

  if ($@) {
    $Self->{db}->end_superlock();
    die $@;
  }

  $Self->{db}->end_superlock();

  my @res;
  push @res, ['MessageSubmission/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  if (%updateMessages or @destroyMessages) {
    push @res, $Self->setMessages({update => \%updateMessages, destroy => \@destroyMessages});
  }

  return @res;
}

1;
