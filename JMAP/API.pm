#!/usr/bin/perl -cw

package JMAP::API;

use JMAP::DB;
use JSON;
use strict;
use warnings;
use Encode;
use HTML::GenerateUtil qw(escape_html);

sub new {
  my $class = shift;
  my $db = shift;

  return bless {db => $db}, ref($class) || $class;
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
    id => $Self->{db}->{accountId},
    name => $user->{displayname} || $user->{email},
    isPrimary => $JSON::true,
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

sub getPreferences {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();

  my @list;

  return ['preferences', {
    defaultPersonalityId => "P1",
  }];
}

sub getSavedSearches {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();

  my @list;

  return ['savedSearches', {
    state => 'dummy',
    list => \@list,
  }];
}

sub getPersonalities {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();

  my @list;
  push @list, {
    id => "P1",
    displayName => $user->{displayname} || $user->{email},
    isDeletable => $JSON::false,
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

  return ['personalities', {
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

sub getMailboxes {
  my $Self = shift;
  my $args = shift;

  # XXX - ideally this is transacted inside the DB
  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $data = $dbh->selectall_arrayref("SELECT * FROM jmailboxes WHERE active = 1", {Slice => {}});

  # outbox - magic
  push @$data, {
    jmailboxid => 'outbox',
    parentId => 0,
    name => 'Outbox',
    role => 'outbox',
    sortOrder => 1,
    mustBeOnlyMailbox => 1,
    mayReadItems => 1,
    mayAddItems => 1,
    mayRemoveItems => 1,
    mayCreateChild => 0,
    mayRename => 0,
    mayDelete => 0,
  };

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
      name => $item->{name},
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

  return ['mailboxes', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%missingids ? [map { "$_" } keys %missingids] : undef),
  }];
}

sub getIdentities {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  return ['identities', {
    accountId => $accountid,
    list => [
      {
        email => $user->{email},
        name => $user->{displayname},
        picture => $user->{picture},
        isDefault => $JSON::true,
      },
    ],
  }];
}

sub getMailboxUpdates {
  my $Self = shift;
  my $args = shift;
  my $dbh = $Self->{db}->dbh();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
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

  my @res = (['mailboxUpdates', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
    onlyCountsChanged => $onlyCounts ? JSON::true : JSON::false,
  }]);

  if (@changed and $args->{fetchRecords}) {
    my %items = (
      accountid => $accountid,
      ids => \@changed,
    );
    if ($onlyCounts) {
      $items{properties} = [qw(totalMessages unreadMessages totalThreads unreadThreads)];
    }
    elsif ($args->{fetchRecordProperties}) {
      $items{properties} = $args->{fetchRecordProperties};
    }
    push @res, $Self->getMailboxes(\%items);
  }

  return @res;
}

sub setMailboxes {
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

  my ($created, $notCreated) = $Self->{db}->create_mailboxes($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_mailboxes($update, sub { $Self->idmap(shift) });
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_mailboxes($destroy);

  $Self->{db}->sync_imap();

  my @res;
  push @res, ['mailboxesSet', {
    accountId => $accountid,
    oldState => undef, # proxy can't guarantee the old state
    newState => undef, # or give a new state
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub _build_sort {
  my $Self = shift;
  my $sortargs = shift;
  return 'internaldate desc' unless $sortargs;
  my %fieldmap = (
    id => 'msgid',
    date => 'internaldate',
    size => 'msgsize',
    isflagged => 'isFlagged',
    isunread => 'isUnread',
    subject => 'msgsubject',
    from => 'msgfrom',
    to => 'msgto',
  );
  my @items;
  $sortargs = [$sortargs] unless ref $sortargs;
  foreach my $arg (@$sortargs) {
    my ($field, $dir) = split / /, lc $arg;
    $dir ||= 'desc';
    die unless ($dir eq 'asc' or $dir eq 'desc');
    die unless $fieldmap{$field};
    push @items, "$fieldmap{$field} $dir";
  }
  push @items, "msgid desc"; # guarantee stable
  return join(', ', @items);
}

sub _load_mailbox {
  my $Self = shift;
  my $id = shift;

  my $data = $Self->{db}->dbh->selectall_arrayref("SELECT msgid,jmodseq,active FROM jmessagemap WHERE jmailboxid = ?", {}, $id);
  return { map { $_->[0] => $_ } @$data };
}

sub _load_hasatt {
  my $Self = shift;
  my $data = $Self->{db}->dbh->selectall_arrayref("SELECT msgid, parsed FROM jrawmessage");
  my %parsed = map { $_->[0] => decode_json($_->[1]) } @$data;
  return { map { $_ => 1 } grep { $parsed{$_}{hasAttachment} } keys %parsed };
}

sub _match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;
  return $Self->_match_operator($item, $condition, $storage) if $condition->{operator};

  if ($condition->{inMailboxes}) {
    my $inall = 1;
    foreach my $id (map { $Self->idmap($_) } @{$condition->{inMailboxes}}) {
      $storage->{mailbox}{$id} ||= $Self->_load_mailbox($id);
      next if $storage->{mailbox}{$id}{$item->{msgid}}[2]; #active
      $inall = 0;
    }
    return 0 unless $inall;
  }

  if ($condition->{notInMailboxes}) {
    my $inany = 0;
    foreach my $id (map { $Self->idmap($_) } @{$condition->{notInMailboxes}}) {
      $storage->{mailbox}{$id} ||= $Self->_load_mailbox($id);
      next unless $storage->{mailbox}{$id}{$item->{msgid}}[2]; #active
      $inany = 1;
    }
    return 0 if $inany;
  }

  if ($condition->{before}) {
    my $time = str2time($condition->{before})->epoch();
    return 0 unless $time < $item->{internaldate};
  }

  if ($condition->{after}) {
    my $time = str2time($condition->{before})->epoch();
    return 0 unless $time >= $item->{internaldate};
  }

  if ($condition->{minSize}) {
    return 0 unless $item->{msgsize} >= $condition->{minSize};
  }

  if ($condition->{maxSize}) {
    return 0 unless $item->{msgsize} < $condition->{maxSize};
  }

  if ($condition->{isFlagged}) {
    # XXX - threaded versions?
    return 0 unless $item->{isFlagged};
  }

  if ($condition->{isUnread}) {
    # XXX - threaded versions?
    return 0 unless $item->{isUnread};
  }

  if ($condition->{isAnswered}) {
    # XXX - threaded versions?
    return 0 unless $item->{isAnswered};
  }

  if ($condition->{isDraft}) {
    # XXX - threaded versions?
    return 0 unless $item->{isDraft};
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
    foreach my $condition ($filter->{conditions}) {
      return 1 if $Self->_match($item, $condition, $storage);
    }
    return 0;
  }
  elsif ($filter->{operator} eq 'AND') {
    foreach my $condition ($filter->{conditions}) {
      return 0 if $Self->_match($item, $condition, $storage);
    }
    return 1;
  }
  die "Invalid operator $filter->{operator}";
}

sub _filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  my @res;
  foreach my $item (@$data) {
    next unless $Self->_match($item, $filter, $storage);
    push @res, $item;
  }
  return \@res;
}

sub _collapse {
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

sub getMessageList {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (exists $args->{position} and exists $args->{anchor});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (not exists $args->{position} and not exists $args->{anchor});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (exists $args->{anchor} and not exists $args->{anchorOffset});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (not exists $args->{anchor} and exists $args->{anchorOffset});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}]) if $start < 0;

  my $sort = $Self->_build_sort($args->{sort});
  my $data = $dbh->selectall_arrayref("SELECT * FROM jmessages WHERE active = 1 ORDER BY $sort", {Slice => {}});

  # commit before applying the filter, because it might call out for searches
  $Self->commit();

  $data = $Self->_filter($data, $args->{filter}, {}) if $args->{filter};
  $data = $Self->_collapse($data) if $args->{collapseThreads};

  if ($args->{anchor}) {
    # need to calculate the position
    for (0..$#$data) {
      next unless $data->[$_][0] eq $args->{anchor};
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
  my @thrid = map { $data->[$_]{thrid} } $start..$end;

  my @res;
  push @res, ['messageList', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    state => "$user->{jhighestmodseq}",
    canCalculateUpdates => $JSON::true,
    position => $start,
    total => scalar(@$data),
    messageIds => [map { "$_" } @result],
    threadIds => [map { "$_" } @thrid],
  }];

  if ($args->{fetchThreads}) {
    push @res, $Self->getThreads({
      ids => \@thrid,
      fetchMessages => $args->{fetchMessages},
      fetchMessageProperties => $args->{fetchMessageProperties},
    }) if @thrid;
  }
  elsif ($args->{fetchMessages}) {
    push @res, $Self->getMessages({
      ids => \@result,
      properties => $args->{fetchMessageProperties},
    }) if @result;
  }

  return @res;
}

sub getMessageListUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $sort = $Self->_build_sort($args->{sort});
  my $data = $dbh->selectall_arrayref("SELECT * FROM jmessages ORDER BY $sort", {Slice => {}});

  $Self->commit();

  # now we have the same sorted data set.  What we DON'T have is knowing that a message used to be in the filter,
  # but no longer is (aka isUnread).  There's no good way to do this :(  So we have to assume that every message
  # which is changed and NOT in the dataset used to be...

  # we also have to assume that it MIGHT have been the exemplar...

  my $tell = 1;
  my $total = 0;
  my $changes = 0;
  my @added;
  my @removed;
  my $storage = {};
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

      if ($changed) {
        # if it's in AND it's the exemplar, it's been added
        if ($isin and $exemplar{$item->{thrid}} eq $item->{msgid}) {
          push @added, {messageId => "$item->{msgid}", threadId => "$item->{thrid}", index => $total-1};
          push @removed, {messageId => "$item->{msgid}", threadId => "$item->{thrid}"};
          $changes++;
        }
        # otherwise it's removed
        else {
          push @removed, {messageId => "$item->{msgid}", threadId => "$item->{thrid}"};
          $changes++;
        }
      }
      # unchanged and isin, final candidate for old exemplar!
      elsif ($isin) {
        # remove it unless it's also the current exemplar
        if ($exemplar{$item->{thrid}} ne $item->{msgid}) {
          push @removed, {messageId => "$item->{msgid}", threadId => "$item->{thrid}"};
          $changes++;
        }
        # and we're done
        $finished{$item->{thrid}} = 1;
      }

      if ($args->{maxChanges} and $changes > $args->{maxChanges}) {
        return $Self->_transError(['error', {type => 'tooManyChanges'}]);
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

      if ($changed) {
        if ($isin) {
          push @added, {messageId => "$item->{msgid}", threadId => "$item->{thrid}", index => $total-1};
          push @removed, {messageId => "$item->{msgid}", threadId => "$item->{thrid}"};
          $changes++;
        }
        else {
          push @removed, {messageId => "$item->{msgid}", threadId => "$item->{thrid}"};
          $changes++;
        }
      }

      if ($args->{maxChanges} and $changes > $args->{maxChanges}) {
        return $Self->_transError(['error', {type => 'tooManyChanges'}]);
      }

      if ($args->{upToMessageId} and $args->{upToMessageId} eq $item->{msgid}) {
        # stop mentioning changes
        $tell = 0;
      }
    }
  }

  my @res;
  push @res, ['messageListUpdates', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    oldState => "$args->{sinceState}",
    newState => "$user->{jhighestmodseq}",
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

sub getSearchSnippets {
  my $Self = shift;
  my $args = shift;

  my $messages = $Self->getMessages({
    accountId => $args->{accountId},
    ids => $args->{messageIds},
    properties => ['subject', 'textBody', 'preview'],
  });

  return $messages unless $messages->[0] eq 'messages';
  $messages->[0] = 'searchSnippets';
  delete $messages->[1]{state};
  $messages->[1]{filter} = $args->{filter};
  $messages->[1]{collapseThreads} = $args->{collapseThreads}, # work around client bug

  my @terms = _extract_terms($args->{filter});
  my $str = join("|", @terms);
  my $tag = 'mark';
  foreach my $item (@{$messages->[1]{list}}) {
    $item->{messageId} = delete $item->{id};
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

sub getMessages {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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
      $item->{mailboxIds} = [map { "$_" } @$ids];
    }

    if (_prop_wanted($args, 'inReplyToMessageId')) {
      $item->{inReplyToMessageId} = $data->{msginreplyto};
    }

    foreach my $bool (qw(isUnread isFlagged isDraft isAnswered hasAttachment)) {
      if (_prop_wanted($args, $bool)) {
        $item->{$bool} = $data->{$bool} ? $JSON::true : $JSON::false;
      }
    }

    foreach my $email (qw(to cc bcc)) {
      if (_prop_wanted($args, $email)) {
        my $val;
        my @addrs = $Self->{db}->parse_emails($data->{"msg$email"});
        $item->{$email} = \@addrs;
      }
    }

    foreach my $email (qw(from replyTo)) {
      if (_prop_wanted($args, $email)) {
        my $val;
        my @addrs = $Self->{db}->parse_emails($data->{"msg$email"});
        $item->{$email} = $addrs[0];
      }
    }

    if (_prop_wanted($args, 'subject')) {
      $item->{subject} = Encode::decode_utf8($data->{msgsubject});
    }

    if (_prop_wanted($args, 'date')) {
      $item->{date} = $Self->{db}->isodate($data->{msgdate});
    }

    if (_prop_wanted($args, 'size')) {
      $item->{size} = $data->{msgsize};
    }

    if (_prop_wanted($args, 'rawUrl')) {
      $item->{rawUrl} = "https://$ENV{jmaphost}/raw/$accountid/$msgid";
    }

    if (_prop_wanted($args, 'blobId')) {
      $item->{blobId} = "$msgid";
    }

    push @list, $item;
  }

  $Self->commit();

  # need to load messages from the server
  if ($need_content) {
    my $content = $Self->{db}->fill_messages('interactive', map { $_->{id} } @list);
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
          $item->{header}{$key} = $data->{headers}{$key};
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

  return ['messages', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%missingids ? [keys %missingids] : undef),
  }];
}

# NOT AN API CALL as such...
sub getRawMessage {
  my $Self = shift;
  my $selector = shift;

  my $msgid = $selector;
  my $part;
  my $filename;
  if ($msgid =~ s{/([^/]+)/?(.*)}{}) {
    $part = $1;
    $filename = $2;
  }

  # skipping transactions here
  my $dbh = $Self->{db}->dbh();
  my ($content) = $dbh->selectrow_array("SELECT rfc822 FROM jrawmessage WHERE msgid = ?", {}, $msgid);
  return unless $content;

  my ($type, $data) = $Self->{db}->get_raw_message($content, $part);
  return ($type, $data, $filename);
}

sub get_file {
  my $Self = shift;
  my $jfileid = shift;

  my $dbh = $Self->{db}->dbh();
  my ($type, $content) = $dbh->selectrow_array("SELECT type, content FROM jfiles WHERE jfileid = ?", {}, $jfileid);
  return unless $content;
  return ($type, $content);
}

# or this
sub uploadFile {
  my $Self = shift;
  my ($type, $content) = @_; # XXX filehandle?

  return $Self->put_file($type, $content);
}

sub downloadFile {
  my $Self = shift;
  my $jfileid = shift;

  my ($type, $content) = $Self->get_file($jfileid);

  return ($type, $content);
}

sub getMessageUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT msgid,active FROM jmessages WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'tooManyChanges'}]);
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
  push @res, ['messageUpdates', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  if ($args->{fetchRecords}) {
    push @res, $Self->getMessages({
      accountid => $accountid,
      ids => \@changed,
      properties => $args->{fetchRecordProperties},
    }) if @changed;
  }

  return @res;
}

sub setMessages {
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

  my ($created, $notCreated) = $Self->{db}->create_messages($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_messages($update, sub { $Self->idmap(shift) });
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_messages($destroy);

  $Self->{db}->sync_imap();

  foreach my $cid (sort keys %$created) {
    my $msgid = $created->{$cid}{id};
    $created->{$cid}{rawUrl} = "https://proxy.jmap.io/raw/$accountid/$msgid";
    $created->{$cid}{blobId} = "$msgid";
  }

  my @res;
  push @res, ['messagesSet', {
    accountId => $accountid,
    oldState => undef, # proxy can't guarantee the old state
    newState => undef, # or give a new state
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub importMessage {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{file};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{mailboxIds};

  my ($type, $message) = $Self->get_file($args->{file});
  return $Self->_transError(['error', {type => 'notFound'}])
    if (not $type or $type ne 'message/rfc822');

  $Self->commit();

  # import to a normal mailbox (or boxes)
  my @ids = map { $Self->idmap($_) } @{$args->{mailboxIds}};
  my ($msgid, $thrid) = $Self->import_message($message, \@ids,
    isUnread => $args->{isUnread},
    isFlagged => $args->{isFlagged},
    isAnswered => $args->{isAnswered},
  );

  my @res;
  push @res, ['messageImported', {
    accountId => $accountid,
    messageId => $msgid,
    threadId => $thrid,
  }];

  return @res;
}

sub copyMessages {
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
    if not $args->{messageIds};

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not exists $args->{asSpam};

  $Self->commit();

  my @ids = map { $Self->idmap($_) } @{$args->{messageIds}};
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

sub getThreads {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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
      messageIds => [map { "$_" } @msgs],
    };
    push @allmsgs, @msgs;
  }

  $Self->commit();

  my @res;
  push @res, ['threads', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%missingids ? [keys %missingids] : undef),
  }];

  if ($args->{fetchMessages}) {
    push @res, $Self->getMessages({
      accountid => $accountid,
      ids => \@allmsgs,
      properties => $args->{fetchMessageProperties},
    }) if @allmsgs;
  }

  return @res;
}

sub getThreadUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT * FROM jmessages WHERE jmodseq > ?";

  if ($args->{maxChanges}) {
    $sql .= " LIMIT " . (int($args->{maxChanges}) + 1);
  }

  my $data = $dbh->selectall_arrayref($sql, {Slice => {}}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'tooManyChanges'}]);
  }

  my %threads;
  my %delcheck;
  foreach my $row (@$data) {
    $threads{$row->{msgid}} = 1;
    $delcheck{$row->{msgid}} = 1 unless $row->{active};
  }

  my @removed;
  foreach my $key (keys %delcheck) {
    my ($exists) = $dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap WHERE thrid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $key);
    unless ($exists) {
      delete $threads{$key};
      push @removed, $key;
    }
  }

  my @changed = keys %threads;

  $Self->commit();

  my @res;
  push @res, ['threadUpdates', {
    accountId => $accountid,
    oldState => $args->{sinceState},
    newState => "$user->{jhighestmodseq}",
    changed => \@changed,
    removed => \@removed,
  }];

  if ($args->{fetchRecords}) {
    push @res, $Self->getThreads({
      accountid => $accountid,
      ids => \@changed,
    }) if @changed;
  }

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
    defaultAlerts             => [],
    defaultAllDayAlerts       => [],
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

sub getCalendars {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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

  return ['calendars', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%missingids ? [map { "$_" } keys %missingids] : undef),
  }];
}

sub getCalendarUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
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

  my @res = (['calendarUpdates', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }]);

  if (@changed and $args->{fetchRecords}) {
    my %items = (
      accountid => $accountid,
      ids => \@changed,
    );
    push @res, $Self->getCalendars(\%items);
  }

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

sub getCalendarEventList {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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
  push @res, ['calendarEventList', {
    accountId => $accountid,
    filter => $args->{filter},
    state => "$user->{jhighestmodseq}",
    position => $start,
    total => scalar(@$data),
    calendarEventIds => [map { "$_" } @result],
  }];

  if ($args->{fetchCalendarEvents}) {
    push @res, $Self->getCalendarEvents({
      ids => \@result,
      properties => $args->{fetchCalendarEventProperties},
    }) if @result;
  }

  return @res;
}

sub getCalendarEvents {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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

  return ['calendarEvents', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%missingids ? [keys %missingids] : undef),
  }];
}

sub getCalendarEventUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT eventuid,active FROM jevents WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'tooManyChanges'}]);
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
  push @res, ['calendarEventUpdates', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  if ($args->{fetchCalendarEvents}) {
    push @res, $Self->getCalendarEvents({
      accountid => $accountid,
      ids => \@changed,
      properties => $args->{fetchCalendarEventProperties},
    }) if @changed;
  }

  return @res;
}

sub getAddressbooks {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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

  return ['addressbooks', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%missingids ? [map { "$_" } keys %missingids] : undef),
  }];
}

sub getAddressbookUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
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

  my @res = (['addressbookUpdates', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }]);

  if (@changed and $args->{fetchRecords}) {
    my %items = (
      accountid => $accountid,
      ids => \@changed,
    );
    push @res, $Self->getAddressbooks(\%items);
  }

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

sub getContactList {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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
  push @res, ['contactList', {
    accountId => $accountid,
    filter => $args->{filter},
    state => "$user->{jhighestmodseq}",
    position => $start,
    total => scalar(@$data),
    contactIds => [map { "$_" } @result],
  }];

  if ($args->{fetchContacts}) {
    push @res, $Self->getContacts({
      ids => \@result,
      properties => $args->{fetchContactProperties},
    }) if @result;
  }

  return @res;
}

sub getContacts {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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

  return ['contacts', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%want ? [keys %want] : undef),
  }];
}

sub getContactUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT contactuid,active FROM jcontacts WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'tooManyChanges'}]);
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
  push @res, ['contactUpdates', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  if ($args->{fetchRecords}) {
    push @res, $Self->getContacts({
      accountid => $accountid,
      ids => \@changed,
      properties => $args->{fetchRecordProperties},
    }) if @changed;
  }

  return @res;
}

sub getContactGroups {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

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

  return ['contactGroups', {
    list => \@list,
    accountId => $accountid,
    state => "$user->{jhighestmodseq}",
    notFound => (%want ? [keys %want] : undef),
  }];
}

sub getContactGroupUpdates {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges'}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT groupuid,active FROM jcontactgroups WHERE jmodseq > ?";

  my $data = $dbh->selectall_arrayref($sql, {}, $args->{sinceState});

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'tooManyChanges'}]);
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
  push @res, ['contactGroupUpdates', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => "$user->{jhighestmodseq}",
    changed => [map { "$_" } @changed],
    removed => [map { "$_" } @removed],
  }];

  if ($args->{fetchRecords}) {
    push @res, $Self->getContactGroups({
      accountid => $accountid,
      ids => \@changed,
      properties => $args->{fetchRecordProperties},
    }) if @changed;
  }

  return @res;
}

sub setContactGroups {
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

  my ($created, $notCreated) = $Self->{db}->create_contact_groups($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_contact_groups($update, sub { $Self->idmap(shift) });
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_contact_groups($destroy);

  $Self->{db}->sync_addressbooks();

  my @res;
  push @res, ['contactGroupsSet', {
    accountId => $accountid,
    oldState => undef, # proxy can't guarantee the old state
    newState => undef, # or give a new state
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub setContacts {
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

  my ($created, $notCreated) = $Self->{db}->create_contacts($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_contacts($update, sub { $Self->idmap(shift) });
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_contacts($destroy);

  $Self->{db}->sync_addressbooks();

  my @res;
  push @res, ['contactsSet', {
    accountId => $accountid,
    oldState => undef, # proxy can't guarantee the old state
    newState => undef, # or give a new state
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub setCalendarEvents {
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

  my ($created, $notCreated) = $Self->{db}->create_calendar_events($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_calendar_events($update, sub { $Self->idmap(shift) });
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendar_events($destroy);

  $Self->{db}->sync_calendars();

  my @res;
  push @res, ['calendarEventsSet', {
    accountId => $accountid,
    oldState => undef, # proxy can't guarantee the old state
    newState => undef, # or give a new state
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub setCalendars {
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

  my ($created, $notCreated) = $Self->{db}->create_calendars($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_calendars($update, sub { $Self->idmap(shift) });
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendars($destroy);

  $Self->{db}->sync_calendars();

  my @res;
  push @res, ['calendarsSet', {
    accountId => $accountid,
    oldState => undef, # proxy can't guarantee the old state
    newState => undef, # or give a new state
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

1;
