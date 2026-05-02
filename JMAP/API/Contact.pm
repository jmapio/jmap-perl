package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;

my $json = JSON::XS->new->utf8->canonical();

sub _contact_name_component {
  my ($card, $kind) = @_;
  my $comps = $card->{name}{components} // [];
  return join(' ', map { $_->{value} // '' }
                   grep { ($_->{kind} // '') eq $kind } @$comps);
}

sub _contact_text_blob {
  my ($card) = @_;
  my @parts;
  push @parts, $card->{name}{full} if $card->{name}{full};
  push @parts, map { $_->{name}    // () } values %{$card->{nicknames}     // {}};
  push @parts, map { $_->{name}    // () } values %{$card->{organizations} // {}};
  push @parts, map { $_->{address} // () } values %{$card->{emails}        // {}};
  push @parts, map { $_->{number}  // () } values %{$card->{phones}        // {}};
  push @parts, map { ($_->{full} // (),
                      map { $_->{value} // () } @{$_->{components} // []}) }
                   values %{$card->{addresses} // {}};
  return join(' ', @parts);
}

sub _contact_match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  if (defined $condition->{inAddressBook}) {
    return 0 unless "$item->{jaddressbookid}" eq "$condition->{inAddressBook}";
  }

  if (defined $condition->{uid}) {
    return 0 unless $item->{contactuid} eq $condition->{uid};
  }

  my @text_keys = qw(text name name/given name/surname name/surname2
                     nickname organization email phone address);
  if (grep { defined $condition->{$_} } @text_keys) {
    my $card = $storage->{payloads}{$item->{contactuid}}
      //= ($Self->{db}->read_jcontact_payload($item->{contactuid}) // {});

    if (defined $condition->{text}) {
      return 0 unless index(lc _contact_text_blob($card), lc $condition->{text}) >= 0;
    }
    if (defined $condition->{name}) {
      return 0 unless index(lc($card->{name}{full} // ''), lc $condition->{name}) >= 0;
    }
    if (defined $condition->{'name/given'}) {
      return 0 unless index(lc _contact_name_component($card, 'given'), lc $condition->{'name/given'}) >= 0;
    }
    if (defined $condition->{'name/surname'}) {
      return 0 unless index(lc _contact_name_component($card, 'surname'), lc $condition->{'name/surname'}) >= 0;
    }
    if (defined $condition->{'name/surname2'}) {
      return 0 unless index(lc _contact_name_component($card, 'surname2'), lc $condition->{'name/surname2'}) >= 0;
    }
    if (defined $condition->{nickname}) {
      my $needle = lc $condition->{nickname};
      return 0 unless grep { index(lc($_->{name} // ''), $needle) >= 0 }
                           values %{$card->{nicknames} // {}};
    }
    if (defined $condition->{organization}) {
      my $needle = lc $condition->{organization};
      return 0 unless grep { index(lc($_->{name} // ''), $needle) >= 0 }
                           values %{$card->{organizations} // {}};
    }
    if (defined $condition->{email}) {
      my $needle = lc $condition->{email};
      return 0 unless grep { index(lc($_->{address} // ''), $needle) >= 0 }
                           values %{$card->{emails} // {}};
    }
    if (defined $condition->{phone}) {
      my $needle = lc $condition->{phone};
      return 0 unless grep { index(lc($_->{number} // ''), $needle) >= 0 }
                           values %{$card->{phones} // {}};
    }
    if (defined $condition->{address}) {
      my $needle = lc $condition->{address};
      return 0 unless grep {
        index(lc(join(' ', $_->{full} // '',
                      map { $_->{value} // '' } @{$_->{components} // []})),
              $needle) >= 0
      } values %{$card->{addresses} // {}};
    }
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

my %CONTACT_SORT_PROPS = map { $_ => 1 }
  qw(created updated name name/given name/surname name/surname2);

my %CONTACT_FILTER_PROPS = map { $_ => 1 }
  qw(inAddressBook uid text name name/given name/surname name/surname2
     nickname organization email phone address);

sub api_Contact_query {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  if ($args->{filter}) {
    my @e = $Self->_check_filter($args->{filter}, \%CONTACT_FILTER_PROPS);
    return @e if @e;
  }

  my $newQueryState = "$user->{jstateContact}";

  my $data = $Self->{db}->dget('jcontacts', { active => 1 }, 'contactuid,jaddressbookid,jcreated,jmodseq');

  my %storage;
  $data = $Self->_contact_filter($data, $args->{filter}, \%storage) if $args->{filter};

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['position']}])
    if ($args->{position} // 0) < 0;

  if ($args->{sort}) {
    for my $cmp (@{$args->{sort}}) {
      return $Self->_transError(['error', {type => 'unsupportedSort', sort => $cmp}])
        unless $CONTACT_SORT_PROPS{$cmp->{property} // ''};
    }
    $data = [sort {
      my $res = 0;
      for my $cmp (@{$args->{sort}}) {
        my $prop = $cmp->{property};
        if ($prop eq 'created') {
          $res = ($a->{jcreated} // 0) <=> ($b->{jcreated} // 0);
        } elsif ($prop eq 'updated') {
          $res = ($a->{jmodseq} // 0) <=> ($b->{jmodseq} // 0);
        } else {
          # name/* sort: load payload
          my $acard = $storage{payloads}{$a->{contactuid}}
            //= ($Self->{db}->read_jcontact_payload($a->{contactuid}) // {});
          my $bcard = $storage{payloads}{$b->{contactuid}}
            //= ($Self->{db}->read_jcontact_payload($b->{contactuid}) // {});
          if ($prop eq 'name') {
            $res = lc($acard->{name}{full} // '') cmp lc($bcard->{name}{full} // '');
          } else {
            my $kind = ($prop =~ s{^name/}{}r);
            $res = lc(_contact_name_component($acard, $kind))
                   cmp lc(_contact_name_component($bcard, $kind));
          }
        }
        $res = -$res if defined($cmp->{isAscending}) && !$cmp->{isAscending};
        last if $res;
      }
      $res || ($a->{contactuid} cmp $b->{contactuid});
    } @$data];
  }

  my ($start, $end) = $Self->_apply_window($data, $args, sub { $_[0]{contactuid} });
  return $Self->_transError(['error', {type => 'anchorNotFound'}]) unless defined $start;

  my @result = map { $data->[$_]{contactuid} } $start..$end;

  $Self->commit();

  my @res;
  push @res, ['Contact/query', {
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

sub api_Contact_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateContact}";

  #properties: String[] A list of properties to fetch for each message.

  my $data = $Self->{db}->dgetby('jcontacts', 'contactuid', { active => 1 }, 'contactuid,jaddressbookid');

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_ => 1 } keys %$data;
  }

  my @list;
  foreach my $id (keys %want) {
    next unless $data->{$id};
    delete $want{$id};

    my $item = $Self->{db}->read_jcontact_payload($id);
    next unless $item;

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $id;
    $item->{addressBookIds} = { "$data->{$id}{jaddressbookid}" => $JSON::true }
      if _prop_wanted($args, 'addressBookIds');

    push @list, $item;
  }
  $Self->commit();

  my %missingids = %want;

  return ['Contact/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Contact_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateContact}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;

  my $data = $Self->{db}->dget('jcontacts', { jmodseq => ['>', $args->{sinceState}] }, 'contactuid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }
  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'contactuid');

  my @res;
  push @res, ['Contact/changes', {
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

  my $scoped_lock = $Self->{db}->begin_superlock();

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

  my @res;
  push @res, ['Contact/set', {
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

sub api_ContactGroup_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateContactGroup}";

  #properties: String[] A list of properties to fetch for each message.

  my $data = $Self->{db}->dgetby('jcontactgroups', 'groupuid', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_ => 1 } keys %$data;
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
      $item->{contactIds} = $Self->{db}->dgetcol('jcontactgroupmap', { groupuid => $id }, 'contactuid');
    }

    push @list, $item;
  }
  $Self->commit();

  my %missingids = %want;

  return ['ContactGroup/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_ContactGroup_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateContactGroup}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;

  my $data = $Self->{db}->dget('jcontactgroups', { jmodseq => ['>', $args->{sinceState}] }, 'groupuid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'groupuid');
  $Self->commit();

  my @res;
  push @res, ['ContactGroup/changes', {
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

  my $scoped_lock = $Self->{db}->begin_superlock();

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

  my @res;
  push @res, ['ContactGroup/set', {
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

sub api_Addressbook_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  # we have no datatype for this yet
  my $newState = "$user->{jhighestmodseq}";

  my $data = $Self->{db}->dget('jaddressbooks', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_->{jaddressbookid} => 1 } @$data;
  }

  my @list;

  foreach my $item (@$data) {
    next unless delete $want{$item->{jaddressbookid}};

    my %rec = (
      id           => "$item->{jaddressbookid}",
      name         => "$item->{name}",
      description  => defined $item->{description} ? "$item->{description}" : $JSON::null,
      sortOrder    => $item->{sortOrder} || 0,
      shareWith    => $JSON::null,
      isDefault    => $item->{isDefault} ? $JSON::true : $JSON::false,
      isSubscribed => $item->{isVisible} ? $JSON::true : $JSON::false,
      myRights     => {
        mayRead   => $item->{mayReadItems}                                          ? $JSON::true : $JSON::false,
        mayWrite  => ($item->{mayAddItems} || $item->{mayModifyItems} || $item->{mayRemoveItems}) ? $JSON::true : $JSON::false,
        mayShare  => $JSON::false,
        mayDelete => $item->{mayDelete}                                             ? $JSON::true : $JSON::false,
      },
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }

  $Self->commit();

  my %missingids = %want;

  return ['Addressbook/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Addressbook_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  # we have no datatype for you yet
  my $newState = "$user->{jhighestmodseq}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $sinceState = $args->{sinceState};

  my $data = $Self->{db}->dget('jaddressbooks', {}, 'jaddressbookid,jmodseq,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @changed = grep { $_->{jmodseq} > $sinceState } @$data;
  my ($created, $updated, $destroyed) = $Self->_classify_changes(\@changed, $sinceState, 'jaddressbookid');

  my @res = (['Addressbook/changes', {
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

# JSContact (RFC 9553) aliases — data is already stored in Card format
sub api_AddressBook_get {
  my $Self = shift;
  my ($r) = $Self->api_Addressbook_get(@_);
  $r->[0] = 'AddressBook/get' if $r && !ref($r->[0]);
  return $r;
}

sub api_AddressBook_changes {
  my $Self = shift;
  my @r = $Self->api_Addressbook_changes(@_);
  $r[0][0] = 'AddressBook/changes' if @r && !ref($r[0][0]);
  return @r;
}

sub api_AddressBook_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $user = $Self->{db}->get_user();
  my $oldState = "$user->{jstateContact}";
  return $Self->_transError(['error', {type => 'stateMismatch', oldState => $oldState, newState => $oldState}])
    if defined $args->{ifInState} and $args->{ifInState} ne $oldState;
  $Self->commit();

  my $create  = $args->{create}  || {};
  my $update  = $args->{update}  || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);

  my $scoped_lock = $Self->{db}->begin_superlock();

  $Self->{db}->sync_addressbooks();

  ($created, $notCreated) = $Self->{db}->create_addressbooks($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_AddressBook_get');
  ($updated, $notUpdated) = $Self->{db}->update_addressbooks($update);

  my (@safe_destroy, %pre_notDestroyed);
  for my $id (@$destroy) {
    $Self->{db}->begin();
    my $has = $Self->{db}->dgetone('jcontacts', { jaddressbookid => $id, active => 1 }, 'contactuid');
    my $contacts;
    if ($has && $args->{onDestroyRemoveContacts}) {
      $contacts = $Self->{db}->dget('jcontacts', { jaddressbookid => $id, active => 1 }, 'contactuid');
    }
    $Self->{db}->commit();
    if ($has && !$args->{onDestroyRemoveContacts}) {
      $pre_notDestroyed{$id} = { type => 'addressBookHasContents' };
    } else {
      if ($has && $contacts) {
        $Self->{db}->destroy_contacts([ map { $_->{contactuid} } @$contacts ]);
      }
      push @safe_destroy, $id;
    }
  }
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_addressbooks(\@safe_destroy);
  $notDestroyed->{$_} = $pre_notDestroyed{$_} for keys %pre_notDestroyed;

  $Self->{db}->sync_addressbooks();

  if (my $osis = $args->{onSuccessSetIsDefault}) {
    for my $id (keys %$osis) {
      my $real_id = $Self->idmap($id) // $id;
      if ($osis->{$id}) {
        $Self->{db}->set_default_addressbook($real_id);
      } else {
        $Self->{db}->unset_default_addressbook($real_id);
      }
    }
  }

  $Self->begin();
  $user = $Self->{db}->get_user();
  my $newState = "$user->{jstateContact}";
  $Self->commit();

  return ['AddressBook/set', {
    accountId    => $accountid,
    oldState     => $oldState,
    newState     => $newState,
    created      => _nullempty($created),
    notCreated   => _nullempty($notCreated),
    updated      => _nullempty($updated),
    notUpdated   => _nullempty($notUpdated),
    destroyed    => _nullempty($destroyed),
    notDestroyed => _nullempty($notDestroyed),
  }];
}

sub api_ContactCard_query {
  my $Self = shift;
  my @r = $Self->api_Contact_query(@_);
  $r[0][0] = 'ContactCard/query' if @r && !ref($r[0][0]);
  return @r;
}

sub api_ContactCard_get {
  my $Self = shift;
  my ($r) = $Self->api_Contact_get(@_);
  $r->[0] = 'ContactCard/get' if $r && !ref($r->[0]);
  return $r;
}

sub api_ContactCard_changes {
  my $Self = shift;
  my @r = $Self->api_Contact_changes(@_);
  $r[0][0] = 'ContactCard/changes' if @r && !ref($r[0][0]);
  return @r;
}

sub api_ContactCard_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  $Self->commit();

  my $create  = $args->{create}  || {};
  my $update  = $args->{update}  || {};
  my $destroy = $args->{destroy} || [];

  my $scoped_lock = $Self->{db}->begin_superlock();
  $Self->{db}->sync_addressbooks();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $oldState = "$user->{jstateContact}";
  return $Self->_transError(['error', {type => 'stateMismatch', oldState => $oldState, newState => $oldState}])
    if defined $args->{ifInState} and $args->{ifInState} ne $oldState;
  $Self->commit();

  # Resolve JSON Pointer patches against ContactCard/get (JSContact format)
  $Self->_resolve_patch($update, 'api_ContactCard_get');

  my ($created, $notCreated) = $Self->{db}->create_contacts_jscontact($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  my ($updated, $notUpdated) = $Self->{db}->update_contacts_jscontact($update);
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_contacts($destroy);

  $Self->{db}->sync_addressbooks();

  $Self->begin();
  $user = $Self->{db}->get_user();
  my $newState = "$user->{jstateContact}";
  $Self->commit();

  return ['ContactCard/set', {
    accountId    => $accountid,
    oldState     => $oldState,
    newState     => $newState,
    created      => _nullempty($created),
    notCreated   => _nullempty($notCreated),
    updated      => _nullempty($updated),
    notUpdated   => _nullempty($notUpdated),
    destroyed    => _nullempty($destroyed),
    notDestroyed => _nullempty($notDestroyed),
  }];
}

sub api_ContactCard_copy {
  my $Self = shift;
  return $Self->_transError(['error', {type => 'notImplemented'}]);
}

sub api_ContactCard_queryChanges {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateContact}";
  my $sinceQueryState = $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    unless $sinceQueryState;
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $sinceQueryState <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jcontacts', { active => 1 }, 'contactuid,jaddressbookid,jmodseq');
  $data = $Self->_contact_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar @$data;

  my %idx;
  my $i = 0;
  $idx{$_->{contactuid}} = $i++ for @$data;

  my $changed = $Self->{db}->dget('jcontacts', { jmodseq => ['>', $sinceQueryState] }, 'contactuid,active');

  $Self->commit();

  my @added;
  my @destroyed;
  for my $row (@$changed) {
    push @destroyed, "$row->{contactuid}";
    if ($row->{active} && exists $idx{$row->{contactuid}}) {
      push @added, { id => "$row->{contactuid}", index => $idx{$row->{contactuid}} };
    }
  }

  return ['ContactCard/queryChanges', {
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

1;
