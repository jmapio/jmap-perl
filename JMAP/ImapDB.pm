#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::ImapDB;
use base qw(JMAP::DB);

use DBI;
use Date::Parse;
use JSON::XS qw(decode_json);
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Digest::SHA qw(sha1_hex);
use Encode;
use Encode::MIME::Header;
use Encode::IMAPUTF7;
use AnyEvent;
use AnyEvent::Socket;
use Date::Format;
use Data::JSEmail;
use Email::Simple;
use Text::JSContact qw(vcard_to_jscontact jscontact_to_vcard);
use Data::Dumper;
use JMAP::Sync::Gmail;
use JMAP::Sync::Standard;
use JMAP::FileNode;
use URI::Escape ();

my $json = JSON::XS->new->utf8->canonical();

our $TAG = 1;

# special use or name magic
my %ROLE_MAP = (
  'inbox' => 'inbox',

  'drafts' => 'drafts',
  'draft' => 'drafts',
  'draft messages' => 'drafts',

  'bulk' => 'junk',
  'bulk mail' => 'junk',
  'junk' => 'junk',
  'junk mail' => 'junk',
  'spam mail' => 'junk',
  'spam messages' => 'junk',

  'archive' => 'archive',
  'sent' => 'sent',
  'sent items' => 'sent',
  'sent messages' => 'sent',

  'deleted messages' => 'trash',
  'trash' => 'trash',

  '\\inbox' => 'inbox',
  '\\trash' => 'trash',
  '\\sent' => 'sent',
  '\\junk' => 'junk',
  '\\spam' => 'junk',
  '\\archive' => 'archive',
  '\\drafts' => 'drafts',
);

sub setuser {
  my $Self = shift;
  my $args = shift;
  require JMAP::CredentialStore;

  # Strip fields that belong to accounts.sqlite3, not the per-account iserver table
  my %iserver = %$args;
  delete $iserver{$_} for qw(poolid accountid force);
  $args = \%iserver;

  # Encrypt the credential before writing
  $args->{password} = JMAP::CredentialStore->encrypt($args->{password})
    if defined $args->{password};

  $Self->begin();

  my $data = $Self->dgetone('iserver');
  if ($data) {
    $Self->dmaybeupdate('iserver', $args);
  }
  else {
    $Self->dinsert('iserver', $args);
  }

  my $user = $Self->dgetone('account');
  if ($user) {
    $Self->dmaybeupdate('account', {email => $args->{username}});
  }
  else {
    $Self->dinsert('account', {
      email => $args->{username},
      jdeletedmodseq => 0,
      jhighestmodseq => 1,
    });
  }

  $Self->commit();
}

sub access_token {
  my $Self = shift;
  require JMAP::CredentialStore;

  $Self->begin();
  my $data = $Self->dgetone('iserver');
  $Self->commit();

  return [$data->{imapHost}, $data->{username},
          JMAP::CredentialStore->decrypt($data->{password}),
          $data->{imapPort}, $data->{imapSSL}];
}

sub access_data {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dgetone('iserver');
  $Self->commit();

  return $data;
}

# synchronous backend for now
sub backend_cmd {
  my $Self = shift;
  my $cmd = shift;
  my @args = @_;

  use Carp;
  Carp::confess("in transaction") if $Self->in_transaction();

  unless ($Self->{backend}) {
    require JMAP::CredentialStore;
    my $config = $Self->access_data();
    $config->{password} = JMAP::CredentialStore->decrypt($config->{password} // '');
    my $backend;
    if ($config->{imapHost} eq 'imap.gmail.com') {
      $backend = JMAP::Sync::Gmail->new($config) || die "failed to setup $config->{username}";
    } elsif ($config->{imapHost} eq 'imap.aol.com') {
      $backend = JMAP::Sync::AOL->new($config) || die "failed to setup $config->{username}";
    } else {
      $backend = JMAP::Sync::Standard->new($config) || die "failed to setup $config->{username}";
    }
    $Self->{backend} = $backend;
  }

  die "No such command $cmd" unless $Self->{backend}->can($cmd);
  return $Self->{backend}->$cmd(@args);
}

# synchronise list from IMAP server to local folder cache
# call in transaction
sub sync_folders {
  my $Self = shift;

  my $data = $Self->backend_cmd('folders');
  my ($prefix, $folders, $sep) = @$data;

  $Self->begin();

  my $ifolders = $Self->dget('ifolders');
  my %ibylabel = map { $_->{label} => $_ } @$ifolders;
  my %seen;

  my %getstatus;
  my %getuniqueid;
  foreach my $name (sort keys %$folders) {
    my $sep = $folders->{$name}[0];
    my $label = $folders->{$name}[1];
    my $id = $ibylabel{$label}{ifolderid};
    if ($id) {
      $Self->dmaybeupdate('ifolders', {sep => $sep, imapname => $name}, {ifolderid => $id});
    }
    else {
      $id = $Self->dinsert('ifolders', {sep => $sep, imapname => $name, label => $label});
    }
    $seen{$id} = 1;
    unless ($ibylabel{$label}{uidvalidity}) {
      # no uidvalidity, we need to get status for this one
      $getstatus{$name} = $id;
    }
    unless ($ibylabel{$label}{uniqueid}) {
      $getuniqueid{$name} = $id;
    }
  }

  foreach my $folder (@$ifolders) {
    my $id = $folder->{ifolderid};
    next if $seen{$id};
    $Self->ddelete('ifolders', {ifolderid => $id});
  }

  $Self->dmaybeupdate('iserver', {imapPrefix => $prefix, imapSep => $sep, lastfoldersync => time()});

  $Self->commit();

  if (keys %getstatus) {
    my $data = $Self->backend_cmd('imap_status', [keys %getstatus]);
    $Self->begin();
    foreach my $name (keys %$data) {
      my $status = $data->{$name};
      next unless ref($status) eq 'HASH';
      $Self->dmaybeupdate('ifolders', {
        uidvalidity => $status->{uidvalidity},
        uidnext => $status->{uidnext},
        uidfirst => $status->{uidnext},
        highestmodseq => $status->{highestmodseq},
      }, {ifolderid => $getstatus{$name}});
    }
    $Self->commit();
  }

  if (keys %getuniqueid) {
    my $data = $Self->backend_cmd('imap_getuniqueid', [keys %getuniqueid]);
    $Self->begin();
    foreach my $name (keys %$data) {
      my $status = $data->{$name};
      next unless ref($status) eq 'HASH';
      eval { $Self->dmaybeupdate('ifolders', {
        uniqueid => $status->{'/vendor/cmu/cyrus-imapd/uniqueid'},
      }, {ifolderid => $getstatus{$name}}); };
    }
    $Self->commit();
  }

  # Fetch MYRIGHTS only for folders that have no rights cached yet.
  # Rights rarely change, so we only check new folders (myrights IS NULL).
  {
    $Self->begin();
    my $current = $Self->dget('ifolders');
    $Self->commit();
    my @need_rights = grep { !defined $_->{myrights} && defined $_->{imapname} } @$current;
    if (@need_rights) {
      my @names = map { $_->{imapname} } @need_rights;
      my $rights_data = eval { $Self->backend_cmd('imap_myrights', \@names) } // {};
      if (%$rights_data) {
        my %byimapname = map { $_->{imapname} => $_ } @need_rights;
        $Self->begin();
        for my $name (keys %$rights_data) {
          my $ifolder = $byimapname{$name};
          next unless $ifolder;
          $Self->dmaybeupdate('ifolders', { myrights => $rights_data->{$name} },
                              { ifolderid => $ifolder->{ifolderid} });
        }
        $Self->commit();
      }
    }
  }

  $Self->sync_jmailboxes();
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jmailboxes {
  my $Self = shift;
  $Self->begin();
  my $ifolders = $Self->dget('ifolders');
  my $jmailboxes = $Self->dget('jmailboxes');

  my %jbyid;
  my %roletoid;
  my %byname;
  foreach my $mailbox (@$jmailboxes) {
    $jbyid{$mailbox->{jmailboxid}} = $mailbox;
    $roletoid{$mailbox->{role}} = $mailbox->{jmailboxid} if $mailbox->{role};
    $byname{$mailbox->{parentId} // ''}{$mailbox->{name}} = $mailbox->{jmailboxid};
  }

  my %seen;
  foreach my $folder (@$ifolders) {
    next if lc $folder->{label} eq "\\allmail"; # we don't show this folder
    my $fname = $folder->{imapname};
    # check for roles first
    my $sep = $folder->{sep};
    my @bits = map { my $b = decode('IMAP-UTF-7', $_); $b =~ s/\^/$sep/g; $b } split "[\Q$sep\E]", $fname;
    shift @bits if ($bits[0] eq 'INBOX' and $bits[1]); # really we should be stripping the actual prefix, if any
    shift @bits if $bits[0] eq '[Gmail]'; # we special case this GMail magic
    next unless @bits; # also skip the magic '[Gmail]' top-level
    my $role = $ROLE_MAP{lc $folder->{label}};
    my $id = undef;
    my $parentId = undef;
    my $name;
    my $sortOrder = 3;
    $sortOrder = 2 if $role;
    $sortOrder = 1 if ($role||'') eq 'inbox';

    # If this ifolder already has a jmailboxid (e.g. from create_mailboxes),
    # and that jmailbox exists, use it directly instead of name-walking.
    if ($folder->{jmailboxid} && $jbyid{$folder->{jmailboxid}}) {
      $id = $folder->{jmailboxid};
      $name = $jbyid{$id}{name};
      $parentId = $jbyid{$id}{parentId};
      # mark intermediates as seen
      my $pid = $parentId;
      while ($pid) {
        $seen{$pid} = 1;
        $pid = $jbyid{$pid} ? $jbyid{$pid}{parentId} : undef;
      }
    }
    else {
      while (my $item = shift @bits) {
        $seen{$id//''} = 1 if $id;
        $name = $item;
        $parentId = $id;
        $id = $byname{$parentId//''}{$name};
        unless ($id) {
          if (@bits) {
            # need to create intermediate folder ...
            # XXX  - label noselect?
            $id = new_uuid_string();
            $Self->dmake('jmailboxes', {
              name => $name,
              jmailboxid => $id,
              sortOrder => 10,  # discovered over IMAP, not created through JMAP
              parentId => $parentId,
            }, 'jnoncountsmodseq');
            $byname{$parentId//''}{$name} = $id;
          }
        }
      }
    }
    next unless $name;
    # Parse MYRIGHTS (RFC 4314) rights string to set per-mailbox permissions.
    # Fall back to all-permitted if no rights were fetched (non-ACL servers).
    my $rights = $folder->{myrights} // '';
    my %r = map { $_ => 1 } split //, $rights;
    my $has_rights = length($rights) > 0;
    my %details = (
      name => $name,
      parentId => $parentId,
      sortOrder => $sortOrder,
      isSubscribed => 1,
      mayReadItems    => $has_rights ? ($r{r} ? 1 : 0) : 1,
      mayAddItems     => $has_rights ? ($r{i} ? 1 : 0) : 1,
      mayRemoveItems  => $has_rights ? (($r{t} && $r{e}) ? 1 : 0) : 1,
      maySetSeen      => $has_rights ? ($r{s} ? 1 : 0) : 1,
      maySetKeywords  => $has_rights ? ($r{w} ? 1 : 0) : 1,
      mayCreateChild  => $has_rights ? ($r{k} ? 1 : 0) : 1,
      mayRename       => $role ? 0 : ($has_rights ? ($r{x} ? 1 : 0) : 1),
      mayDelete       => $role ? 0 : ($has_rights ? ($r{x} ? 1 : 0) : 1),
      maySubmit       => 1,
      mayAdmin        => $has_rights ? ($r{a} ? 1 : 0) : 1,
    );
    if ($id) {
      if ($role and $roletoid{$role} and $roletoid{$role} ne $id) {
        # still gotta move it
        $id = $roletoid{$role};
        $Self->dmaybedirty('jmailboxes', {active => 1, %details}, {jmailboxid => $id}, 'jnoncountsmodseq');
      }
      elsif (not $folder->{active}) {
        # reactivate!
        $Self->dmaybedirty('jmailboxes', {active => 1}, {jmailboxid => $id}, 'jnoncountsmodseq');
      }
    }
    else {
      # case: role - we need to see if there's a case for moving this thing
      if ($role and $roletoid{$role}) {
        $id = $roletoid{$role};
        $Self->dmaybedirty('jmailboxes', {active => 1, %details}, {jmailboxid => $id}, 'jnoncountsmodseq');
      }
      else {
        $id = $folder->{uniqueid} || new_uuid_string();
        $Self->dmake('jmailboxes', {role => $role, jmailboxid => $id, %details}, 'jnoncountsmodseq');
        $byname{$parentId//''}{$name} = $id;
        $roletoid{$role} = $id if $role;
      }
    }
    $seen{$id//''} = 1;
    $Self->dmaybeupdate('ifolders', {jmailboxid => $id}, {ifolderid => $folder->{ifolderid}});
  }

  foreach my $mailbox (@$jmailboxes) {
    my $id = $mailbox->{jmailboxid};
    next unless $mailbox->{active};
    next if $seen{$id};
    $Self->dmaybeupdate('jmailboxes', {active => 0}, {jmailboxid => $id}, 'jnoncountsmodseq');
  }

  $Self->commit();
}

# synchronise list from CalDAV server to local folder cache
sub sync_calendars {
  my $Self = shift;

  my $calendars = $Self->backend_cmd('get_calendars', []);
  return unless $calendars;

  $Self->begin();

  my $icalendars = $Self->dget('icalendars');
  my %byhref = map { $_->{href} => $_ } @$icalendars;

  my %seen;
  my %todo;
  foreach my $calendar (@$calendars) {
    my $id = $calendar->{href} ? $byhref{$calendar->{href}}{icalendarid} : 0;
    my $data = {
      isReadOnly => $calendar->{isReadOnly},
      href => $calendar->{href},
      color => $calendar->{color},
      name => $calendar->{name},
    };
    if ($id) {
      my $token = $byhref{$calendar->{href}}{syncToken};
      if ($token && $calendar->{syncToken} && $token eq $calendar->{syncToken}) {
        $seen{$id} = 1;
        next;
      }
      $Self->dmaybeupdate('icalendars', $data, {icalendarid => $id});
    }
    else {
      $id = $Self->dinsert('icalendars', $data);
    }
    $todo{$id} = 1;
    $seen{$id} = 1;
  }

  foreach my $calendar (@$icalendars) {
    my $id = $calendar->{icalendarid};
    next if $seen{$id};
    $Self->ddelete('icalendars', {icalendarid => $id});
  }

  $Self->sync_jcalendars();

  $Self->commit();

  $Self->do_calendars(\%todo);
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jcalendars {
  my $Self = shift;

  my $icalendars = $Self->dget('icalendars');
  my $jcalendars = $Self->dget('jcalendars');

  my %jbyid;
  foreach my $calendar (@$jcalendars) {
    $jbyid{$calendar->{jcalendarid}} = $calendar;
  }

  my %seen;
  foreach my $calendar (@$icalendars) {
    my $data = {
      name => $calendar->{name},
      color => $calendar->{color},
      isVisible => 1,
      mayReadFreeBusy => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayModifyItems => 1,
      mayRemoveItems => 1,
      mayDelete => 1,
      mayRename => 1,
    };
    my $id = $calendar->{jcalendarid};
    if ($id && $jbyid{$id}) {
      $Self->dmaybedirty('jcalendars', $data, {jcalendarid => $id});
    }
    else {
      $id = $Self->dmake('jcalendars', $data);
      $Self->dupdate('icalendars', {jcalendarid => $id}, {icalendarid => $calendar->{icalendarid}});
    }
    $seen{$id} = 1;
  }

  foreach my $calendar (@$jcalendars) {
    my $id = $calendar->{jcalendarid};
    next if $seen{$id};
    $Self->dnuke('jcalendars', {jcalendarid => $id});
    $Self->dnuke('jevents', {jcalendarid => $id});
  }
}

sub do_calendars {
  my $Self = shift;
  my $cals = shift;

  # filter stage
  $Self->begin();
  my %exists;
  foreach my $id (keys %$cals) {
    my $cal = $Self->dgetone('icalendars', {icalendarid => $id});
    next unless $cal;
    my $exists = $Self->dget('ievents', {icalendarid => $id});
    $exists{$id} = [ $cal, { map { $_->{href} => $_ } @$exists } ];
  }
  $Self->commit();

  my %todo;
  foreach my $id (keys %exists) {
    my $cal = $exists{$id}[0];
    my $href = $cal->{href};
    my $oldtoken = $cal->{syncToken};
    my ($added, $removed, $errors, $newToken) = eval { $Self->backend_cmd('sync_event_links', $href, $oldtoken) };

    unless ($newToken) {
      # try fetching from nothing
      ($added, $removed, $errors, $newToken) = $Self->backend_cmd('sync_event_links', $href);
      # calculate removed by comparing exists to fetched list
      foreach my $href (keys %{$exists{$id}[1]}) {
        push @$removed, $href unless $added->{$href};
      }
    }

    $todo{$id} = [$newToken, {}];

    foreach my $href (@$removed) {
      $todo{$id}[1]{$href} = undef;
    }

    my @toget;
    foreach my $href (keys %$added) {
      next if (exists $exists{$id}[1]{$href} and $exists{$id}[1]{$href}{etag} eq $added->{$href});
      push @toget, $href;
    }

    if (@toget) {
      my ($events, $errors, $links) = $Self->backend_cmd('get_events_multi', $href, \@toget, Full => 1);
      foreach my $href (keys %$events) {
        my $parsed = $Self->parse_event($events->{$href});
        $todo{$id}[1]{$href} = [$links->{$href}, $events->{$href}, $parsed];
      }
    }
  }

  $Self->begin();
  foreach my $id (keys %todo) {
    my $newtoken = $todo{$id}[0];
    my $changes = $todo{$id}[1];

    my $jcalendarid = $Self->dgetfield('icalendars', { icalendarid => $id }, 'jcalendarid');

    foreach my $href (keys %$changes) {
      my $change = $changes->{$href};
      my $existing = $exists{$id}[1]{$href};

      if ($change) {
        my $uid = $change->[2]{uid};
        $Self->write_event_ical($uid, encode_utf8($change->[1]));

        my $item = {
          icalendarid => $id,
          uid         => $uid,
          href        => $href,
          etag        => $change->[0],
        };

        if ($existing) {
          $Self->dmaybeupdate('ievents', $item, {ieventid => $existing->{ieventid}});
        }
        else {
          $Self->dinsert('ievents', $item);
        }

        $Self->set_event($jcalendarid, $change->[2]);
      }
      elsif ($existing) {
        $Self->unlink_event_ical($existing->{uid});
        $Self->ddelete('ievents', {ieventid => $existing->{ieventid}});
        $Self->delete_event($jcalendarid, $existing->{uid});
      }
    }

    $Self->dupdate('icalendars', {syncToken => $newtoken}, {jcalendarid => $id});
  }

  $Self->commit();
}

sub create_calendars {
  my $Self = shift;
  my $new  = shift;

  return ({}, {}) unless keys %$new;

  my %createmap;
  my %notcreated;

  for my $cid (sort keys %$new) {
    my $cal = $new->{$cid};
    unless (defined $cal->{name} && $cal->{name} ne '') {
      $notcreated{$cid} = { type => 'invalidProperties', properties => ['name'] };
      next;
    }
    my $uid = new_uuid_string();
    my $args = { id => $uid, name => $cal->{name} };
    $args->{color}     = $cal->{color}     if defined $cal->{color};
    $args->{isVisible} = $cal->{isVisible} if exists $cal->{isVisible};
    eval { $Self->backend_cmd('new_calendar', $args) };
    if ($@) {
      $notcreated{$cid} = { type => 'serverFail', description => "$@" };
      next;
    }

    # sync to pick up the new calendar and get its jcalendarid
    $Self->sync_calendars();

    $Self->begin();
    my $ical = $Self->dgetone('icalendars', {}, 'href,jcalendarid');
    # find the newly created one by matching the uuid in the href
    my $all = $Self->dget('icalendars', {});
    my ($found) = grep { ($_->{href} // '') =~ m{\Q$uid\E} } @$all;
    $Self->commit();

    if ($found && $found->{jcalendarid}) {
      my $new_id = $found->{jcalendarid};
      # Persist locally-managed properties that CalDAV sync doesn't carry.
      my %local;
      $local{description} = $cal->{description} if exists $cal->{description};
      $local{timeZone}    = $cal->{timeZone}     if exists $cal->{timeZone};
      if (exists $cal->{defaultAlertsWithTime}) {
        require JSON::XS;
        $local{defaultAlertsWithTime} = defined $cal->{defaultAlertsWithTime}
          ? JSON::XS->new->utf8->encode($cal->{defaultAlertsWithTime}) : undef;
      }
      if (exists $cal->{defaultAlertsWithoutTime}) {
        require JSON::XS;
        $local{defaultAlertsWithoutTime} = defined $cal->{defaultAlertsWithoutTime}
          ? JSON::XS->new->utf8->encode($cal->{defaultAlertsWithoutTime}) : undef;
      }
      if (%local) {
        $Self->begin();
        $Self->dupdate('jcalendars', \%local, { jcalendarid => $new_id });
        $Self->commit();
      }
      $createmap{$cid} = { id => "$new_id" };
    } else {
      $notcreated{$cid} = { type => 'serverFail', description => 'calendar created but not found after sync' };
    }
  }

  return (\%createmap, \%notcreated);
}

sub update_calendars {
  my $Self = shift;
  my $changes = shift;

  return ({}, {}) unless keys %$changes;

  my %changed;
  my %notchanged;

  for my $jcalendarid (sort keys %$changes) {
    my $patch = $changes->{$jcalendarid};

    $Self->begin();
    my $ical = $Self->dgetone('icalendars', { jcalendarid => $jcalendarid }, 'href');
    $Self->commit();

    unless ($ical) {
      $notchanged{$jcalendarid} = { type => 'notFound' };
      next;
    }

    # extract the calendar ID (last path component) from the href
    (my $cal_id = $ical->{href}) =~ s{.*/([^/]+)/?$}{$1};

    my %args = ( id => $cal_id );
    $args{name}      = $patch->{name}      if exists $patch->{name};
    $args{color}     = $patch->{color}     if exists $patch->{color};
    $args{isVisible} = $patch->{isVisible} if exists $patch->{isVisible};

    eval { $Self->backend_cmd('update_calendar', \%args) };
    if ($@) {
      $notchanged{$jcalendarid} = { type => 'serverFail', description => "$@" };
      next;
    }

    # Persist locally-managed properties (not synced via CalDAV).
    my %local;
    $local{description} = $patch->{description} if exists $patch->{description};
    $local{timeZone}    = $patch->{timeZone}     if exists $patch->{timeZone};
    if (exists $patch->{defaultAlertsWithTime}) {
      require JSON::XS;
      $local{defaultAlertsWithTime} = defined $patch->{defaultAlertsWithTime}
        ? JSON::XS->new->utf8->encode($patch->{defaultAlertsWithTime}) : undef;
    }
    if (exists $patch->{defaultAlertsWithoutTime}) {
      require JSON::XS;
      $local{defaultAlertsWithoutTime} = defined $patch->{defaultAlertsWithoutTime}
        ? JSON::XS->new->utf8->encode($patch->{defaultAlertsWithoutTime}) : undef;
    }
    if (%local) {
      $Self->begin();
      $Self->dupdate('jcalendars', \%local, { jcalendarid => $jcalendarid });
      $Self->commit();
    }

    $changed{$jcalendarid} = undef;
  }

  $Self->sync_calendars() if keys %changed;

  return (\%changed, \%notchanged);
}

sub destroy_calendars {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  my @destroyed;
  my %notdestroyed;

  for my $jcalendarid (@$destroy) {
    $Self->begin();
    my $ical = $Self->dgetone('icalendars', { jcalendarid => $jcalendarid }, 'href');
    $Self->commit();

    unless ($ical) {
      $notdestroyed{$jcalendarid} = { type => 'notFound' };
      next;
    }

    (my $cal_id = $ical->{href}) =~ s{.*/([^/]+)/?$}{$1};

    eval { $Self->backend_cmd('delete_calendar', $cal_id) };
    if ($@) {
      $notdestroyed{$jcalendarid} = { type => 'serverFail', description => "$@" };
      next;
    }

    push @destroyed, $jcalendarid;
  }

  $Self->sync_calendars() if @destroyed;

  return (\@destroyed, \%notdestroyed);
}

# synchronise list from CardDAV server to local folder cache
# call in transaction
sub sync_addressbooks {
  my $Self = shift;

  my $addressbooks = $Self->backend_cmd('get_addressbooks', []);
  return unless $addressbooks;

  $Self->begin();

  my $iaddressbooks = $Self->dget('iaddressbooks');
  my %byhref = map { $_->{href} => $_ } @$iaddressbooks;

  my %seen;
  my %todo;
  foreach my $addressbook (@$addressbooks) {
    my $id = $addressbook->{href} ? $byhref{$addressbook->{href}}{iaddressbookid} : 0;
    my $data = {
      isReadOnly => $addressbook->{isReadOnly},
      href => $addressbook->{href},
      name => $addressbook->{name},
    };
    if ($id) {
      my $token = $byhref{$addressbook->{href}}{syncToken};
      if ($token && $addressbook->{syncToken} && $token eq $addressbook->{syncToken}) {
        $seen{$id} = 1;
        next;
      }
      $Self->dmaybeupdate('iaddressbooks', $data, {iaddressbookid => $id});
    }
    else {
      $id = $Self->dinsert('iaddressbooks', $data);
    }
    $todo{$id} = $addressbook->{syncToken};
    $seen{$id} = 1;
  }

  foreach my $addressbook (@$iaddressbooks) {
    my $id = $addressbook->{iaddressbookid};
    next if $seen{$id};
    $Self->ddelete('iaddressbooks', {iaddressbookid => $id});
  }

  $Self->sync_jaddressbooks();

  $Self->commit();

  $Self->do_addressbooks(\%todo);
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jaddressbooks {
  my $Self = shift;

  my $iaddressbooks = $Self->dget('iaddressbooks');
  my $jaddressbooks = $Self->dget('jaddressbooks');

  my %jbyid;
  foreach my $addressbook (@$jaddressbooks) {
    next unless $addressbook->{jaddressbookid};
    $jbyid{$addressbook->{jaddressbookid}} = $addressbook;
  }

  my %seen;
  foreach my $addressbook (@$iaddressbooks) {
    my $aid = $addressbook->{iaddressbookid};
    my $data = {
      name => $addressbook->{name},
      isVisible => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayModifyItems => 1,
      mayRemoveItems => 1,
      mayDelete => 0,
      mayRename => 0,
    };
    my $jid = $addressbook->{jaddressbookid};
    if ($jid && $jbyid{$jid}) {
      $Self->dmaybedirty('jaddressbooks', $data, {jaddressbookid => $jid});
      $seen{$jid} = 1;
    }
    else {
      $jid = $Self->dmake('jaddressbooks', $data);
      $Self->dupdate('iaddressbooks', {jaddressbookid => $jid}, {iaddressbookid => $aid});
      $seen{$jid} = 1;
    }
  }

  foreach my $addressbook (@$jaddressbooks) {
    my $jid = $addressbook->{jaddressbookid};
    next if $seen{$jid};
    $Self->dnuke('jaddressbooks', {jaddressbookid => $jid});
    $Self->dnuke('jcontactgroups', {jaddressbookid => $jid});
    $Self->dnuke('jcontacts', {jaddressbookid => $jid});
  }
}

sub create_addressbooks {
  my $Self = shift;
  my $new  = shift;

  return ({}, {}) unless keys %$new;

  my %createmap;
  my %notcreated;

  for my $cid (sort keys %$new) {
    my $ab = $new->{$cid};
    unless (defined $ab->{name} && $ab->{name} ne '') {
      $notcreated{$cid} = { type => 'invalidProperties', properties => ['name'] };
      next;
    }
    my $uid = new_uuid_string();
    eval { $Self->backend_cmd('new_addressbook', { id => $uid, name => $ab->{name} }) };
    if ($@) {
      $notcreated{$cid} = { type => 'serverFail', description => "$@" };
      next;
    }

    $Self->sync_addressbooks();

    $Self->begin();
    my $all = $Self->dget('iaddressbooks', {});
    my ($found) = grep { ($_->{href} // '') =~ m{\Q$uid\E} } @$all;
    $Self->commit();

    if ($found && $found->{jaddressbookid}) {
      $createmap{$cid} = { id => "$found->{jaddressbookid}" };
    } else {
      $notcreated{$cid} = { type => 'serverFail', description => 'addressbook created but not found after sync' };
    }
  }

  return (\%createmap, \%notcreated);
}

sub update_addressbooks {
  my $Self = shift;
  my $changes = shift;

  return ({}, {}) unless keys %$changes;

  my %changed;
  my %notchanged;

  for my $jaddressbookid (sort keys %$changes) {
    my $patch = $changes->{$jaddressbookid};

    $Self->begin();
    my $iab = $Self->dgetone('iaddressbooks', { jaddressbookid => $jaddressbookid }, 'href');
    $Self->commit();

    unless ($iab) {
      $notchanged{$jaddressbookid} = { type => 'notFound' };
      next;
    }

    (my $ab_id = $iab->{href}) =~ s{.*/([^/]+)/?$}{$1};

    my %args = ( id => $ab_id );
    $args{name} = $patch->{name} if exists $patch->{name};

    if (exists $patch->{name}) {
      eval { $Self->backend_cmd('update_addressbook', \%args) };
      if ($@) {
        $notchanged{$jaddressbookid} = { type => 'serverFail', description => "$@" };
        next;
      }
    }

    # Persist local-only fields directly to DB
    my %local;
    $local{description} = $patch->{description} if exists $patch->{description};
    $local{sortOrder}   = $patch->{sortOrder}   if exists $patch->{sortOrder};
    $local{isVisible}   = $patch->{isSubscribed} ? 1 : 0 if exists $patch->{isSubscribed};
    if (%local) {
      $Self->begin();
      $Self->ddirty('jaddressbooks', \%local, { jaddressbookid => $jaddressbookid });
      $Self->commit();
    }

    $changed{$jaddressbookid} = undef;
  }

  $Self->sync_addressbooks() if keys %changed;

  return (\%changed, \%notchanged);
}

sub destroy_addressbooks {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  my @destroyed;
  my %notdestroyed;

  for my $jaddressbookid (@$destroy) {
    $Self->begin();
    my $iab = $Self->dgetone('iaddressbooks', { jaddressbookid => $jaddressbookid }, 'href');
    $Self->commit();

    unless ($iab) {
      $notdestroyed{$jaddressbookid} = { type => 'notFound' };
      next;
    }

    (my $ab_id = $iab->{href}) =~ s{.*/([^/]+)/?$}{$1};

    eval { $Self->backend_cmd('delete_addressbook', $ab_id) };
    if ($@) {
      $notdestroyed{$jaddressbookid} = { type => 'serverFail', description => "$@" };
      next;
    }

    push @destroyed, $jaddressbookid;
  }

  $Self->sync_addressbooks() if @destroyed;

  return (\@destroyed, \%notdestroyed);
}

sub set_default_addressbook {
  my ($Self, $jaddressbookid) = @_;
  $Self->begin();
  $Self->dbh->do("UPDATE jaddressbooks SET isDefault = 0 WHERE active = 1");
  $Self->dbh->do("UPDATE jaddressbooks SET isDefault = 1 WHERE jaddressbookid = ? AND active = 1", {}, $jaddressbookid);
  $Self->commit();
}

sub do_addressbooks {
  my $Self = shift;
  my $books = shift;

  # filter stage
  $Self->begin();
  my %exists;
  foreach my $id (keys %$books) {
    my $book = $Self->dgetone('iaddressbooks', {iaddressbookid => $id});
    next unless $book;
    my $exists = $Self->dget('icards', {iaddressbookid => $id});
    $exists{$id} = [ $book, { map { $_->{href} => $_ } @$exists } ];
  }
  $Self->commit();

  my %todo;
  foreach my $id (keys %exists) {
    my $book = $exists{$id}[0];
    my $href = $book->{href};
    my $oldtoken = $book->{syncToken};
    my ($added, $removed, $errors, $newToken) = eval { $Self->backend_cmd('sync_card_links', $href, $oldtoken) };
    unless ($newToken) {
      # fake up a sync by getting everything
      ($added, $removed, $errors, $newToken) = eval { $Self->backend_cmd('sync_card_links', $href) };
      # calculate removed by comparing exists to fetched list
      foreach my $href (keys %{$exists{$id}[1]}) {
        push @$removed, $href unless $added->{$href};
      }
    }

    # token
    $todo{$id} = [$newToken, {}];

    foreach my $href (@$removed) {
      $todo{$id}[1]{$href} = undef;
    }

    my @toget;
    foreach my $href (keys %$added) {
      next if (exists $exists{$id}[1]{$href} and $exists{$id}[1]{$href}{etag} eq $added->{$href});
      push @toget, $href;
    }
    if (@toget) {
      my ($cards, $errors, $links) = $Self->backend_cmd('get_cards_multi', $href, \@toget, Full => 1);
      foreach my $href (keys %$cards) {
        my $parsed = $Self->parse_card($cards->{$href});
        $todo{$id}[1]{$href} = [$links->{$href}, $cards->{$href}, $parsed];
      }
    }
  }

  $Self->begin();
  foreach my $id (keys %todo) {
    my $newtoken = $todo{$id}[0];
    my $changes = $todo{$id}[1];

    my $jaddressbookid = $Self->dgetfield('iaddressbooks', { iaddressbookid => $id }, 'jaddressbookid');

    foreach my $href (keys %$changes) {
      my $change = $changes->{$href};
      my $existing = $exists{$id}[1]{$href};

      if ($change) {
        my $uid = $change->[2]{uid};
        $Self->write_card_vcf($uid, encode_utf8($change->[1]));

        my $item = {
          iaddressbookid => $id,
          uid            => $uid,
          kind           => $change->[2]{kind},
          href           => $href,
          etag           => $change->[0],
        };

        if ($existing) {
          $Self->dmaybeupdate('icards', $item, {icardid => $existing->{icardid}});
        }
        else {
          $Self->dinsert('icards', $item);
        }

        $Self->set_card($jaddressbookid, $change->[2]);
      }
      elsif ($existing) {
        $Self->unlink_card_vcf($existing->{uid});
        $Self->ddelete('icards', {icardid => $existing->{icardid}});
        $Self->delete_card($jaddressbookid, $existing->{uid}, $existing->{kind});
      }
    }

    $Self->dupdate('iaddressbooks', {syncToken => $newtoken}, {jaddressbookid => $id});
  }

  $Self->commit();
}

# --- FileNode over WebDAV (docs/superpowers/specs/2026-10-09-filenode-webdav-design.md) ---
#
# Every WebDAV request goes through backend_cmd, which refuses to run inside
# a transaction: each function below reads what it needs, commits, talks to
# the server, and only then opens the transaction that writes the mirror.

# The FileNode root: the unescaped path of the account's webdavURL, or undef.
sub files_root {
  my $Self = shift;
  $Self->begin();
  my $url = $Self->dgetfield('iserver', {}, 'webdavURL');
  $Self->commit();
  return undef unless $url;
  (my $path = $url) =~ s{^https?://[^/]+}{};
  $path = URI::Escape::uri_unescape($path);
  $path = eval { Encode::decode_utf8($path, Encode::FB_CROAK) } // $path;
  $path =~ s{/+$}{};
  return $path;
}

# What the server really supports (Probe), worked out once per account and
# kept in iserver.webdavFeatures.  A probe that fails is not cached, so a
# server that was briefly down is probed again next time.
sub filenode_features {
  my $Self = shift;
  return $Self->{_filefeatures} if $Self->{_filefeatures};
  $Self->begin();
  my $json = $Self->dgetfield('iserver', {}, 'webdavFeatures');
  $Self->commit();
  my $f = $json ? eval { decode_json($json) } : undef;
  unless (ref $f eq 'HASH') {
    my $root = $Self->files_root() or return {};
    $f = eval { $Self->backend_cmd('files_probe', $root) };
    unless (ref $f eq 'HASH') {
      warn "filenode_features: probe failed: $@";
      return {};
    }
    $Self->begin();
    $Self->dupdate('iserver', { webdavFeatures => JSON::XS::encode_json($f) });
    $Self->commit();
  }
  return $Self->{_filefeatures} = $f;
}

# call in transaction
sub filenode_rows {
  my $Self = shift;
  return $Self->dget('jfilenodes', { active => 1 });
}

# call in transaction
sub filenode_row {
  my ($Self, $nodeid) = @_;
  return $Self->dgetone('jfilenodes', { nodeid => $nodeid, active => 1 });
}

# One mirror row's columns from a listing entry.  The columns hold only what
# the SERVER reports, because reconcile matches on them (a moved file is
# found by its server size + getlastmodified).  Client-set values (the J:
# dead properties: created, modified, accessed, executable, isSubscribed)
# are kept as they are in deadprops, and _filenode_object lays them over the
# columns (spec "Properties without a WebDAV home").
sub _filenode_cols {
  my ($e) = @_;
  my $name = $e->{href} =~ m{([^/]+)$} ? $1 : $e->{href};
  my $dir = $e->{isCollection};
  my $dead = $e->{dead} || {};
  return (
    href        => $e->{href},
    name        => $name,
    nodetype    => $dir ? 'directory' : 'file',
    etag        => $e->{etag},
    ctag        => $e->{ctag},
    size        => $dir ? undef : ($e->{size} // 0),
    type        => $dir ? undef : ($e->{type} || 'application/octet-stream'),
    created     => $e->{created} // $e->{modified},
    modified    => $e->{modified},
    fileid      => $e->{fileid},
    fingerprint => $e->{sha1},
    privs       => defined $e->{privileges} ? join(' ', @{$e->{privileges}}) : undef,
    deadprops   => JMAP::FileNode::dead_json($dead),
  );
}

# Walk the whole tree, one collection at a time, with PROPFIND Depth 1 (spec
# "Sync"): an unchanged collection ETag is never a reason to skip a subtree.
# Only direct children of the collection asked about are taken, and each
# collection is listed once, so a bogus listing cannot make the walk loop.
# A root the server would not describe at Depth 0 is synthesised and marked
# {synthetic}: it only stands in for the root, it never overwrites its row.
sub _files_walk {
  my ($Self, $root) = @_;
  my ($rootentry) = grep { !$_->{missing} && $_->{href} eq $root }
                    @{ $Self->backend_cmd('files_prop_find', "$root/", 0) };
  $rootentry ||= { href => $root, dead => {}, synthetic => 1 };
  $rootentry->{isCollection} = 1;
  my @listing = ($rootentry);
  my %seen = ($root => 1);
  my @todo = ($root);
  while (defined(my $dir = shift @todo)) {
    my $entries = $Self->backend_cmd('files_prop_find', "$dir/", 1);
    for my $e (@$entries) {
      next if $e->{missing};
      next unless $e->{href} =~ m{^\Q$dir\E/[^/]+\z};
      next if $e->{href} =~ m{/\.jmap-probe-[^/]*\z};   # filenode_features' scratch file
      next if $seen{$e->{href}}++;
      push @listing, $e;
      push @todo, $e->{href} if $e->{isCollection};
    }
  }
  return \@listing;
}

# One full sync of the WebDAV tree into jfilenodes.  Returns 1 when a
# listing was applied, 0 when the mirror kept changing under the walk, and
# nothing when the account has no webdavURL.  Dies if the server fails.
#
# The walk runs outside any transaction, so by the time it is applied the
# mirror may have moved on: a proxy write (FileNode/set) or another worker's
# sync (the jmap and backfill workers share the DB).  Applying a listing
# taken before such a change could undo it -- destroy a node the proxy just
# created, or recreate one it just destroyed -- so a listing is only applied
# if no jfilenodes row got a modseq after the walk began; otherwise it is
# thrown away and the tree walked again.
sub sync_files {
  my $Self = shift;
  my $root = $Self->files_root() or return;
  my $features = $Self->filenode_features();
  for my $try (1 .. 3) {
    $Self->begin();
    my $walkseq = $Self->get_user()->{jhighestmodseq} // 0;
    $Self->commit();
    my $listing = $Self->_files_walk($root);
    $Self->begin();
    if ($Self->dcount('jfilenodes', { jmodseq => ['>', $walkseq] })) {
      $Self->rollback();
      next;
    }
    $Self->_apply_file_listing($root, $listing, $features);
    $Self->commit();
    return 1;
  }
  warn "sync_files: the mirror changed during every walk; leaving it for the next sync\n";
  return 0;
}

# call in transaction: reconcile one complete listing into jfilenodes.
sub _apply_file_listing {
  my ($Self, $root, $listing, $features) = @_;
  my $mirror = $Self->filenode_rows();
  my $plan = JMAP::FileNode::reconcile($mirror, $listing, $features);
  my %id_by_href = map { $_->{href} => $_->{nodeid} } @$mirror;
  delete $id_by_href{ $_->{href} } for @{$plan->{destroy}};
  $id_by_href{ $_->[1]{href} } = $_->[0]{nodeid} for @{$plan->{update}};
  $id_by_href{ $_->{href} } = $_->{nodeid} for @{$plan->{create}};
  my $parent_of = sub {
    my $href = shift;
    return undef if $href eq $root;
    (my $p = $href) =~ s{/[^/]+$}{};
    return $id_by_href{$p};
  };
  my $now = time();
  for my $e (@{$plan->{create}}) {
    $Self->dmake('jfilenodes', {
      executable => 0, isSubscribed => 1,
      _filenode_cols($e),
      nodeid => $e->{nodeid}, parentid => $parent_of->($e->{href}),
      changed => $now,
      role => ($e->{href} eq $root ? 'home' : undef),
    });
  }
  my %privs_changed;
  for my $u (@{$plan->{update}}) {
    my ($row, $e) = @$u;
    next if $e->{synthetic};   # we learnt nothing about the root: keep its row
    # Only what really differs: reconcile also counts fields the mirror
    # stores normalised (a directory's type, a missing size).
    my %cols = (parentid => $parent_of->($e->{href}), _filenode_cols($e));
    my %diff = map { $_ => $cols{$_} } grep { ($row->{$_} // '') ne ($cols{$_} // '') } keys %cols;
    next unless %diff;
    # A node is only "changed" (new modseq, new "changed" time) when a
    # FileNode property changes.  The href alone (an ancestor was renamed),
    # a directory's ETag/ctag (Cyrus changes them whenever a child changes),
    # fileid and fingerprint are the mirror's bookkeeping, not properties.
    # deadprops IS a change: it holds client-visible values.
    my @visible = grep {
      !/^(?:href|ctag|fileid|fingerprint)\z/ && !($_ eq 'etag' && $cols{nodetype} eq 'directory')
    } keys %diff;
    if (@visible) {
      $Self->ddirty('jfilenodes', { %diff, changed => $now }, { nodeid => $row->{nodeid} });
    }
    else {
      $Self->dupdate('jfilenodes', \%diff, { nodeid => $row->{nodeid} });
    }
    $privs_changed{$row->{nodeid}} = 1 if exists $diff{privs};
  }
  # draft S5: a child's mayRename/mayDelete come from its parent's
  # privileges, so the children of a node whose privileges changed are
  # changed too.
  for my $nodeid (sort keys %privs_changed) {
    $Self->ddirty('jfilenodes', { changed => $now }, { parentid => $nodeid, active => 1 });
  }
  for my $row (@{$plan->{destroy}}) {
    $Self->ddirty('jfilenodes', { active => 0, changed => $now }, { nodeid => $row->{nodeid} });
  }
  $Self->dupdate('iserver', { lastfilesync => $now });
}

# Run a file sync, and never die.  A failure (or a sync that gave up because
# the mirror kept changing under its walks) is still recorded as the last
# sync, so a broken or unreachable WebDAV server is not walked again on every
# FileNode call and tick: the next attempt waits for the usual age.
sub sync_files_safely {
  my $Self = shift;
  my $ok = eval { $Self->sync_files() };
  if (defined $ok) {
    return 1 if $ok;
  }
  else {
    my $err = $@;
    $Self->reset();
    warn "sync_files: $err";
  }
  eval {
    $Self->begin();
    $Self->dupdate('iserver', { lastfilesync => time() });
    $Self->commit();
    1;
  } or $Self->reset();
  return 0;
}

# Sync when the last one is older than $maxage seconds (spec "Sync": 60 on
# demand from a FileNode method, 300 from the periodic sync).  Never dies.
# An account that has never synced its files is left alone unless
# $opts->{first} is true: its first full walk belongs to the backfill worker
# (first_files_sync), and only a FileNode request -- a user waiting on the
# answer -- may run it sooner.
sub sync_files_if_due {
  my ($Self, $maxage, $opts) = @_;
  return unless $Self->files_root();
  $Self->begin();
  my $last = $Self->dgetfield('iserver', {}, 'lastfilesync');
  $Self->commit();
  return if !defined $last && !($opts && $opts->{first});
  return if time() - ($last // 0) < $maxage;
  $Self->sync_files_safely();
}

# The account's first full file sync, which runs in the backfill worker so
# that signing up never waits for a big walk (spec "Sync").  Does nothing
# once any sync has run.  Never dies.
sub first_files_sync {
  my $Self = shift;
  return unless $Self->files_root();
  $Self->begin();
  my $last = $Self->dgetfield('iserver', {}, 'lastfilesync');
  $Self->commit();
  return if defined $last;
  $Self->sync_files_safely();
}



sub labels {
  my $Self = shift;

  my $data = $Self->dget('ifolders');
  return { map { $_->{label} => [$_->{ifolderid}, $_->{jmailboxid}, $_->{imapname}] } @$data };
}

sub sync_imap {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dget('ifolders');
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }
  $Self->commit();

  my @imapnames = map { $_->{imapname} } @$data;
  my $status = $Self->backend_cmd('imap_status', \@imapnames);

  foreach my $row (@$data) {
    # XXX - better handling of UIDvalidity change?
    next if ($status->{$row->{imapname}}{uidvalidity} == $row->{uidvalidity} and $status->{$row->{imapname}}{highestmodseq} and $status->{$row->{imapname}}{highestmodseq} == $row->{highestmodseq});
    my $label = $row->{label};
    $label = undef if lc $label eq '\\allmail';
    $Self->do_folder($row->{ifolderid}, $label);
  }

  $Self->sync_jmap();
}

sub backfill {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dget('ifolders', { uidnext => ['>', 1], uidfirst => ['>', 1] }, 'mtime,ifolderid,label');
  $Self->commit();

  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }

  return unless @$data;

  #DB::enable_profile();
  my $rest = 500;
  foreach my $row (@$data) {
    my $id = $row->{ifolderid};
    my $label = $row->{label};
    $label = undef if lc $label eq '\\allmail';
    $rest -= $Self->do_folder($id, $label, $rest);
    last if $rest < 10;
  }
  #DB::disable_profile();
  #exit 0;

  $Self->sync_jmap();

  return 1;
}

sub firstsync {
  my $Self = shift;

  $Self->sync_folders();

  $Self->begin();
  my $data = $Self->dget('ifolders');
  $Self->commit();

  if ($Self->{is_gmail}) {
    my ($folder) = grep { lc $_->{label} eq '\\allmail' } @$data;
    $Self->do_folder($folder->{ifolderid}, undef, 50) if $folder;
  }
  else {
    my ($folder) = grep { lc $_->{imapname} eq 'inbox' } @$data;
    $Self->do_folder($folder->{ifolderid}, $folder->{label}, 50) if $folder;
  }

  $Self->sync_jmap();

  # Know the account's calendars and address books from the start, so the
  # first /get reports what the server already has and a later /changes does
  # not present pre-existing collections as newly created.
  for my $sync (qw(sync_calendars sync_addressbooks)) {
    eval { $Self->$sync(); 1 } or do { $Self->reset(); warn "firstsync: $sync failed: $@" };
  }
}

sub _trimh {
  my $val = shift;
  return '' unless defined $val;
  $val =~ s{\s+$}{};
  $val =~ s{^\s+}{};
  return $val;
}

sub calclabels {
  my $Self = shift;
  my $forcelabel = shift;
  my $data = shift;

  return ($forcelabel) if $forcelabel;
  return (@{$data->{'x-gm-labels'}}) if $data->{'x-gm-labels'};
  die "No way to calculate labels for " . Dumper($data);
}

sub calcmsgid {
  my $Self = shift;
  my $imapname = shift;
  my $uid = shift;
  my $data = shift;

  return ($data->{"x-gm-msgid"}, $data->{"x-gm-thrid"})
    if ($data->{"x-gm-msgid"} and $data->{"x-gm-thrid"});

  return ($data->{"digest.sha1"}, $data->{"cid"})
    if ($data->{"digest.sha1"} and $data->{"cid"});

  my $envelope = $data->{envelope};
  my $coded = $json->encode([$envelope]);
  my $base = substr(sha1_hex($coded), 0, 9);
  my $msgid = "m$base";

  my $replyto = _trimh($envelope->{'In-Reply-To'});
  my $messageid = _trimh($envelope->{'Message-ID'});
  my $encsub = eval { Encode::decode('MIME-Header', $envelope->{Subject}) };
  $encsub = $envelope->{Subject} unless defined $encsub;
  my $sortsub = _normalsubject($encsub);

  # Thread by In-Reply-To/Message-ID first (JMAP threading model),
  # then fall back to subject-based threading
  my ($thrid) = $Self->dbh->selectrow_array(
    "SELECT DISTINCT thrid FROM ithread WHERE messageid IN (?, ?)",
    {}, $replyto, $messageid);
  $thrid ||= "t$base";
  foreach my $id ($replyto, $messageid) {
    next if $id eq '';
    $Self->dbh->do("INSERT OR IGNORE INTO ithread (messageid, thrid, sortsubject) VALUES (?, ?, ?)", {}, $id, $thrid, $sortsub);
  }

  return ($msgid, $thrid);
}

sub do_folder {
  my $Self = shift;
  my $ifolderid = shift;
  my $forcelabel = shift;
  my $batchsize = shift;

  Carp::confess("NO FOLDERID") unless $ifolderid;

  $Self->begin();
  my $data = $Self->dgetone('ifolders', {ifolderid => $ifolderid});
  $Self->commit();

  die "NO SUCH FOLDER $ifolderid" unless $data;
  my $imapname = $data->{imapname};
  my $uidfirst = $data->{uidfirst};
  my $uidvalidity = $data->{uidvalidity};
  my $uidnext = $data->{uidnext};
  my $highestmodseq = $data->{highestmodseq};

  my %fetches;

  if ($batchsize) {
    if ($uidfirst > 1) {
      my $end = $uidfirst - 1;
      $uidfirst -= $batchsize;
      $uidfirst = 1 if $uidfirst < 1;
      $fetches{backfill} = [$uidfirst, $end, 1];
    }
  }
  else {
    $fetches{new} = [$uidnext, '*', 1];
    $fetches{update} = [$uidfirst, $uidnext - 1, 0, $highestmodseq];
  }

  return unless keys %fetches;

  my $res = $Self->backend_cmd('imap_fetch', $imapname, {
    uidvalidity => $uidvalidity,
    highestmodseq => $highestmodseq,
    uidnext => $uidnext,
  }, \%fetches);

  if ($res->{newstate}{uidvalidity} != $uidvalidity) {
    # going to want to nuke everything for the existing folder and create this - but for now, just die
    use Data::Dumper;
    die "UIDVALIDITY CHANGED $imapname: $uidvalidity => $res->{newstate}{uidvalidity}" . Dumper($data);
  }

  $Self->begin();
  $Self->{t}{backfilling} = 1 if $batchsize;

  my $didold = 0;
  if ($res->{backfill}) {
    my $new = $res->{backfill}[1];
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
      my @labels = $Self->calclabels($forcelabel, $new->{$uid});
      $didold++;
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, \@labels, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  if ($res->{update}) {
    my $changed = $res->{update}[1];
    foreach my $uid (sort { $a <=> $b } keys %$changed) {
      my @labels = $Self->calclabels($forcelabel, $changed->{$uid});
      $Self->changed_record($ifolderid, $uid, $changed->{$uid}{'flags'}, \@labels);
    }
  }

  if ($res->{new}) {
    my $new = $res->{new}[1];
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
      my @labels = $Self->calclabels($forcelabel, $new->{$uid});
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, \@labels, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  $Self->dupdate('ifolders', {highestmodseq => $res->{newstate}{highestmodseq}, uidfirst => $uidfirst, uidnext => $res->{newstate}{uidnext}}, {ifolderid => $ifolderid});

  $Self->commit();

  return $didold if $batchsize;

  # need to make changes before counting
  $Self->begin();
  # DBNOTE: because of COUNT not being supported
  my ($count) = $Self->dbh->selectrow_array("SELECT COUNT(*) FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
  $Self->commit();

  # if we don't know everything, we have to ALWAYS check or moves break
  if ($uidfirst != 1 or $count != $res->{newstate}{exists}) {
    # welcome to the future
    $uidnext = $res->{newstate}{uidnext};
    my $to = $uidnext - 1;
    $Self->log('debug', "COUNTING $imapname: $uidfirst:$to (something deleted)");
    my $res = $Self->backend_cmd('imap_count', $imapname, $uidvalidity, "$uidfirst:$to");
    $Self->begin();
    my $uids = $res->{data};
    # DBNOTE: because of multiple expressions on same key not being supported
    my $data = $Self->dbh->selectcol_arrayref("SELECT uid FROM imessages WHERE ifolderid = ? AND uid >= ? AND uid <= ?", {}, $ifolderid, $uidfirst, $to);
    my %exists = map { $_ => 1 } @$uids;
    foreach my $uid (@$data) {
      next if $exists{$uid};
      $Self->deleted_record($ifolderid, $uid);
    }
    $Self->commit();
  }
}

sub imap_search {
  my $Self = shift;
  my @search = @_;

  if ($Self->{is_gmail}) {
    if ($search[0] eq 'text') {
      @search = ('x-gm-raw', $search[1]);
    }
    if ($search[0] eq 'from') {
      @search = ('x-gm-raw', "from:$search[1]");
    }
    if ($search[0] eq 'to') {
      @search = ('x-gm-raw', "to:$search[1]");
    }
    if ($search[0] eq 'cc') {
      @search = ('x-gm-raw', "cc:$search[1]");
    }
    if ($search[0] eq 'subject') {
      @search = ('x-gm-raw', "subject:$search[1]");
    }
    if ($search[0] eq 'body') {
      @search = ('x-gm-raw', $search[1]);
    }
  }

  $Self->begin();
  my $data = $Self->dget('ifolders');
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }
  $Self->commit();

  my %matches;
  foreach my $item (@$data) {
    my $from = $item->{uidfirst};
    my $to = $item->{uidnext}-1;
    next if $from > $to;  # empty folder
    my $res = $Self->backend_cmd('imap_search', $item->{imapname}, 'uid', "$from:$to", @search);
    # XXX - uidvaldity changed
    next unless $res->[2] == $item->{uidvalidity};
    $Self->begin();
    foreach my $uid (@{$res->[3]}) {
      my $msgid = $Self->dgetfield('imessages', { ifolderid => $item->{ifolderid}, uid => $uid }, 'msgid');
      $matches{$msgid} = 1 if $msgid;
    }
    $Self->commit();
  }

  return \%matches;
}

sub mark_sync {
  my $Self = shift;
  my ($msgid) = @_;
  # DBNOTE: because of IGNORE not being supported (maybe)
  $Self->dbh->do("INSERT OR IGNORE INTO imsgidtodo (msgid) VALUES (?)", {}, $msgid);
}

sub changed_record {
  my $Self = shift;
  my ($ifolderid, $uid, $flaglist, $labellist) = @_;

  my $flags = $json->encode([grep { lc $_ ne '\\recent' } sort @$flaglist]);
  my $labels = $json->encode([sort @$labellist]);

  return unless $Self->dmaybeupdate('imessages', {flags => $flags, labels => $labels}, {ifolderid => $ifolderid, uid => $uid});

  my $msgid = $Self->dgetfield('imessages', { ifolderid => $ifolderid, uid => $uid }, 'msgid');

  $Self->mark_sync($msgid);
}

sub import_message {
  my $Self = shift;
  my $rfc822 = shift;
  my $mailboxIds = shift;
  my $keywords = shift || {};
  my $internaldate = shift;

  $Self->begin();
  my $folderdata = $Self->dget('ifolders');
  $Self->commit();

  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;

  # store to the first named folder - we can use labels on gmail to add to other folders later.
  my ($id, @others) = @$mailboxIds;
  my $imapname = $jmailmap{$id}{imapname};
  my $uidvalidity = $jmailmap{$id}{uidvalidity};

  my %flags = %$keywords;
  my @flags;
  push @flags, "\\Answered" if delete $flags{'$answered'};
  push @flags, "\\Flagged" if delete $flags{'$flagged'};
  push @flags, "\\Draft" if delete $flags{'$draft'};
  push @flags, "\\Seen" if delete $flags{'$seen'};
  push @flags, sort keys %flags;

  my $date = Date::Format::time2str('%e-%b-%Y %T %z', $internaldate);

  my $appendres = $Self->backend_cmd('imap_append', $imapname, "(@flags)", $date, $rfc822);
  # XXX - compare $appendres->[2] with uidvalidity
  my $uid = $appendres->[3];

  # make sure we're up to date: XXX - imap only
  my $ifolderid;
  if ($Self->{is_gmail}) {
    my ($am) = grep { lc $_->{label} eq '\\allmail' } @$folderdata;
    $Self->do_folder($am->{ifolderid}, undef);
    $ifolderid = $am->{ifolderid};
  }
  else {
    # copy to all the other folders too and sync them
    for my $folder (@others) {
      my $newfolder = $jmailmap{$folder}{imapname};
      my $fdata = $jmailmap{$folder};
      $Self->backend_cmd('imap_copy', $imapname, $uidvalidity, $uid, $newfolder);
      $Self->do_folder($fdata->{ifolderid}, $fdata->{label});
    }
    # sync this folder
    my $fdata = $jmailmap{$id};
    $Self->do_folder($fdata->{ifolderid}, $fdata->{label});
    $ifolderid = $fdata->{ifolderid};
  }

  $Self->begin();
  my $msgdata = $Self->dgetone('imessages', { ifolderid => $ifolderid, uid => $uid }, 'msgid,thrid,size');
  $Self->commit();

  # XXX - did we fail to sync this back?  Annoying
  die "FAILED TO GET BACK STORED MESSAGE FROM IMAP SERVER" unless $msgdata;

  # save us having to download it again - drop out of transaction so we don't wait on the parse
  my $message = Data::JSEmail::parse($rfc822, $msgdata->{msgid});

  $Self->write_parsed_msg($msgdata->{msgid}, $message);

  $Self->begin();
  $Self->dinsert('jrawmessage', {
    msgid         => $msgdata->{msgid},
    hasAttachment => $message->{hasAttachment},
  });
  $Self->commit();

  return ($msgdata->{msgid}, $msgdata->{thrid}, $msgdata->{size});
}

sub update_messages {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();

  my %notchanged;
  my %changed;

  my %map;
  foreach my $msgid (keys %$changes) {
    my $data = $Self->dget('imessages', { msgid => $msgid }, 'ifolderid,uid');
    if (@$data) {
      foreach my $row (@$data) {
        $map{$msgid}{$row->{ifolderid}}{$row->{uid}} = 1;
      }
    }
    else {
      $notchanged{$msgid} = {type => 'notFound', description => "No such message on server"};
    }
  }

  my $folderdata = $Self->dget('ifolders');
  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;
  my $jmapdata = $Self->dget('jmailboxes');
  my %jidmap = map { $_->{jmailboxid} => ($_->{role} || '') } @$jmapdata;
  my %jrolemap = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$jmapdata;

  $Self->commit();

  foreach my $msgid (keys %map) {
    my $action = $changes->{$msgid};

    # A mailboxIds entry naming a mailbox that does not exist -- including an
    # unresolved "#creationId" from a later call in the same request -- must
    # reject the update. Letting it through copied the message nowhere and then
    # removed it from every folder it was in.
    if (exists $action->{mailboxIds}) {
      my @unknown = grep {
        !exists $jidmap{$_} or (!$Self->{is_gmail} and !$jmailmap{$_})
      } map { $idmap->($_) } keys %{ $action->{mailboxIds} || {} };
      if (@unknown or !%{ $action->{mailboxIds} || {} }) {
        $notchanged{$msgid} = {
          type        => 'invalidProperties',
          properties  => ['mailboxIds'],
          description => @unknown ? "no such mailbox: @unknown" : "mailboxIds must not be empty",
        };
        next;
      }
    }

    eval {
                        foreach my $ifolderid (sort keys %{$map{$msgid}}) {
                                my @uids = sort keys %{$map{$msgid}{$ifolderid}};
                                # XXX - merge similar actions?
                                my $imapname = $foldermap{$ifolderid}{imapname};
                                my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
                                next unless ($imapname and $uidvalidity);
                                if (exists $action->{keywords}) {
                                        my %flags = %{$action->{keywords}};
                                        my @flags;
                                        push @flags, "\\Answered" if delete $flags{'$answered'};
                                        push @flags, "\\Flagged" if delete $flags{'$flagged'};
                                        push @flags, "\\Draft" if delete $flags{'$draft'};
                                        push @flags, "\\Seen" if delete $flags{'$seen'};
                                        push @flags, sort keys %flags;
                                        $Self->log('debug', "STORING (@flags) for @uids");
                                        $Self->backend_cmd('imap_update', $imapname, $uidvalidity, \@uids, \@flags);
                                }
                        }
                        if (exists $action->{mailboxIds}) {
                                # jmailboxid
                                my @mboxes = map { $idmap->($_) } keys %{$action->{mailboxIds}};

                                # existing ifolderids containing this message
                                # identify a source message to work from
                                my ($ifolderid) = sort keys %{$map{$msgid}};
                                my $imapname = $foldermap{$ifolderid}{imapname};
                                my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
                                my ($uid) = sort keys %{$map{$msgid}{$ifolderid}};

                                if ($Self->{is_gmail}) {
                                        # because 'archive' is synthetic on gmail we strip it here
                                        (@mboxes) = grep { $jidmap{$_} ne 'archive' } @mboxes;
                                        my @labels = grep { $_ and lc $_ ne '\\allmail' } map { $jmailmap{$_}{label} } @mboxes;
                                        $Self->backend_cmd('imap_labels', $imapname, $uidvalidity, $uid, \@labels);
                                }
                                else {
                                        # existing ifolderids with this message
                                        my %current = map { $_ => 1 } keys %{$map{$msgid}};
                                        # new ifolderids that should contain this message
                                        my %new = map { $jmailmap{$_}{ifolderid} => 1 } @mboxes;

                                        # for all the new folders
                                        foreach my $ifolderid (sort keys %new) {
                                                # unless there's already a matching message in it
                                                next if delete $current{$ifolderid};
                                                # copy from the existing message
                                                my $newfolder = $foldermap{$ifolderid}{imapname};
                                                $Self->backend_cmd('imap_copy', $imapname, $uidvalidity, $uid, $newfolder);
                                        }
                                        foreach my $ifolderid (sort keys %current) {
                                                # these ifolderids didn't exist in %new, so delete all matching UIDs from these folders
                                                my $imapname = $foldermap{$ifolderid}{imapname};
                                                my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
                                                my @uids = sort keys %{$map{$msgid}{$ifolderid}};
                                                $Self->backend_cmd('imap_move', $imapname, $uidvalidity, \@uids);
                                        }
                                }
                        }
    };
    if ($@) {
      $notchanged{$msgid} = { type => 'error', description => $@ };
    }
    else {
      $changed{$msgid} = undef;
    }
  }

  return (\%changed, \%notchanged);
}

sub destroy_messages {
  my $Self = shift;
  my $ids = shift;

  return ([], {}) unless @$ids;

  $Self->begin();
  my %destroymap;
  my %notdestroyed;
  foreach my $msgid (@$ids) {
    my $data = $Self->dget('imessages', { msgid => $msgid }, 'ifolderid,uid');
    if (@$data) {
      foreach my $row (@$data) {
        $destroymap{$row->{ifolderid}}{$row->{uid}} = $msgid;
      }
    }
    else {
      $notdestroyed{$msgid} = {type => 'notFound', description => "No such message on server"};
    }
  }

  my $folderdata = $Self->dget('ifolders');
  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;

  $Self->commit();

  my @destroyed;
  foreach my $ifolderid (keys %destroymap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}{imapname};
    my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
    unless ($imapname) {
      $notdestroyed{$_} = {type => 'notFound', description => "No folder"} for values %{$destroymap{$ifolderid}};
    }
    my $uids = [sort keys %{$destroymap{$ifolderid}}];
    $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uids, undef); # no destination folder
    push @destroyed, values %{$destroymap{$ifolderid}};
  }

  return (\@destroyed, \%notdestroyed);
}

sub deleted_record {
  my $Self = shift;
  my ($ifolderid, $uid) = @_;

  my $msgid = $Self->dgetfield('imessages', { ifolderid => $ifolderid, uid => $uid }, 'msgid');
  return unless $msgid;

  $Self->ddelete('imessages', {ifolderid => $ifolderid, uid => $uid});

  $Self->mark_sync($msgid);
}

sub new_record {
  my $Self = shift;
  my ($ifolderid, $uid, $flaglist, $labellist, $envelope, $internaldate, $msgid, $thrid, $size) = @_;

  my $flags = $json->encode([grep { lc $_ ne '\\recent' } sort @$flaglist]);
  my $labels = $json->encode([sort @$labellist]);

  my $data = {
    ifolderid => $ifolderid,
    uid => $uid,
    flags => $flags,
    labels => $labels,
    internaldate => $internaldate,
    msgid => $msgid,
    thrid => $thrid,
    envelope => $json->encode($envelope),
    size => $size,
  };

  # delete first to correctly handle msgid changes (shouldn't be possible, but whatever)
  $Self->deleted_record($ifolderid, $uid);
  $Self->dinsert('imessages', $data);

  $Self->mark_sync($msgid);
}

sub sync_jmap_msgid {
  my $Self = shift;
  my ($msgid) = @_;

  my $imessages = $Self->dget('imessages', { msgid => $msgid }, 'flags, labels');

  my %labels;
  my %flags;
  foreach my $row (@$imessages) {
    my $flaglist = decode_json($row->{flags});
    my $labellist = decode_json($row->{labels});
    $flags{$_} = 1 for @$flaglist;
    $labels{$_} = 1 for @$labellist;
  }

  my %flagdata;
  foreach my $flag (keys %flags) {
    my $lcf = lc $flag;
    if ($lcf eq '\\seen') {
      $flagdata{'$seen'} = $JSON::true;
    }
    elsif ($lcf eq '\\flagged') {
      $flagdata{'$flagged'} = $JSON::true;
    }
    elsif ($lcf eq '\\draft') {
      $flagdata{'$draft'} = $JSON::true;
    }
    elsif ($lcf eq '\\answered') {
      $flagdata{'$answered'} = $JSON::true;
    }
    else {
      $flagdata{$lcf} = $JSON::true;
    }
  }

  my @list = keys %labels;

  # gmail empty list means archive at our end
  my $labels = $Self->labels();
  my @jmailboxids = grep { $_ } map { $labels->{$_}[1] } @list;

  # check for archive folder for gmail
  if ($Self->{is_gmail} and @$imessages and not @list) {
    @jmailboxids = ($Self->dgetfield('jmailboxes', { role => 'archive' }, 'jmailboxid'));
  }

  return $Self->delete_message($msgid) if (not @jmailboxids);

  my $old = $Self->dgetfield('jmessages', { msgid => $msgid, active => 1 }, 'msgid');

  $Self->log('debug', "DATA (@jmailboxids) for $msgid");

  if ($old) {
    $Self->log('debug', "changing $msgid");
    return $Self->change_message($msgid, {keywords => \%flagdata}, \@jmailboxids);
  }
  else {
    $Self->log('debug', "adding $msgid");
    my $data = $Self->dgetone('imessages', { msgid => $msgid }, 'thrid,internaldate,size,envelope');
    return $Self->add_message({
      msgid => $msgid,
      internaldate => $data->{internaldate},
      thrid => $data->{thrid},
      msgsize => $data->{size},
      keywords => \%flagdata,
      isDraft => $flagdata{'$draft'} ? 1 : 0,
      isUnread => $flagdata{'$seen'} ? 0 : 1,
      _envelopedata($data->{envelope}),
    }, \@jmailboxids);
  }
}

sub sync_jmap {
  my $Self = shift;
  $Self->begin();
  my $msgids = $Self->dgetcol('imsgidtodo', {}, 'msgid');
  foreach my $msgid (@$msgids) {
    $Self->sync_jmap_msgid($msgid);
    $Self->ddelete('imsgidtodo', { msgid => $msgid });
  }
  $Self->commit();
}

sub _normalsubject {
  my $sub = shift;
  return unless defined $sub;

  # Re: and friends
  $sub =~ s/^[ \t]*[A-Za-z0-9]+://g;
  # [LISTNAME] and friends
  $sub =~ s/^[ \t]*\\[[^]]+\\]//g;
  # Australian security services and frenemies
  $sub =~ s/[\\[(SEC|DLM)=[^]]+\\][ \t]*$//g;
  # any old whitespace
  $sub =~ s/[ \t\r\n]+//g;

  return $sub;
}

sub _envelopedata {
  my $data = shift;
  my $envelope = decode_json($data || "{}");
  my $encsub = eval { Encode::decode('MIME-Header', $envelope->{Subject}) };
  $encsub = $envelope->{Subject} unless defined $encsub;
  my $sortsub = _normalsubject($encsub);
  return (
    msgsubject => $encsub,
    sortsubject => $sortsub,
    msgfrom => $envelope->{From},
    msgto => $envelope->{To},
    msgcc => $envelope->{Cc},
    msgbcc => $envelope->{Bcc},
    msgdate => str2time($envelope->{Date}),
    msginreplyto => _trimh($envelope->{'In-Reply-To'}),
    msgmessageid => _trimh($envelope->{'Message-ID'}),
  );
}

sub fill_messages {
  my $Self = shift;
  my @ids = @_;

  return {} unless @ids;

  $Self->begin();

  my %result;
  my @need;
  for my $msgid (@ids) {
    my $msg = $Self->read_parsed_msg($msgid);
    if ($msg) {
      $result{$msgid} = $msg;
    } else {
      push @need, $msgid;
    }
  }

  my %udata;
  if (@need) {
    # DBNOTE: because of IN not being supported
    my $uids = $Self->dbh->selectall_arrayref("SELECT ifolderid, uid, msgid FROM imessages WHERE msgid IN (" . join(', ', map { "?" } @need) . ")", {}, @need);
    foreach my $row (@$uids) {
      my ($ifolderid, $uid, $msgno) = @$row;
      $udata{$ifolderid}{$uid} = $msgno;
    }
  }

  my %foldermap;
  foreach my $ifolderid (sort keys %udata) {
    my $uhash = $udata{$ifolderid};
    my $uids = join(',', sort { $a <=> $b } grep { not $result{$uhash->{$_}} } keys %$uhash);
    next unless $uids;
    my $data = $Self->dgetone('ifolders', { ifolderid => $ifolderid }, 'imapname,uidvalidity');
    next unless $data;
    $foldermap{$ifolderid} = [$data->{imapname}, $data->{uidvalidity}];
  }

  # drop out of transaction to actually fetch the data
  $Self->commit();

  return \%result unless keys %udata;

  my %parsed;
  foreach my $ifolderid (sort keys %udata) {
    my $uhash = $udata{$ifolderid};
    my $uids = join(',', sort { $a <=> $b } grep { not $result{$uhash->{$_}} } keys %$uhash);
    next unless $uids;

    my $data = $foldermap{$ifolderid};
    next unless $data;

    my ($imapname, $uidvalidity) = @$data;
    my $res = $Self->backend_cmd('imap_fill', $imapname, $uidvalidity, $uids);
    foreach my $uid (keys %{$res->{data}}) {
      my $rfc822 = $res->{data}{$uid};
      next unless $rfc822;
      my $msgid = $uhash->{$uid};
      next if $result{$msgid};
      $result{$msgid} = $parsed{$msgid} = Data::JSEmail::parse($rfc822, $msgid);
    }
  }

  foreach my $msgid (sort keys %parsed) {
    $Self->write_parsed_msg($msgid, $parsed{$msgid});
  }

  $Self->begin();
  foreach my $msgid (sort keys %parsed) {
    my $message = $parsed{$msgid};
    $Self->dinsert('jrawmessage', {
      msgid        => $msgid,
      hasAttachment => $message->{hasAttachment},
    });
  }
  $Self->commit();

  # XXX - handle not getting data that we need?
  my @stillneed = grep { not $result{$_} } @ids;

  return \%result;
}

sub find_type {
  my $message = shift;
  my $part = shift;


  return $message->{type} if ($message->{partId} || '') eq $part;

  foreach my $sub (@{$message->{subParts}}) {
    my $type = find_type($sub, $part);
    return $type if $type;
  }
}

sub get_raw_message {
  my $Self = shift;
  my $msgid = shift;
  my $part = shift;

  $Self->begin();
  # DBNOTE: because of JOIN not being supported
  my ($imapname, $uidvalidity, $uid) = $Self->dbh->selectrow_array("SELECT imapname, uidvalidity, uid FROM ifolders JOIN imessages USING (ifolderid) WHERE msgid = ?", {}, $msgid);
  $Self->commit();
  return unless $imapname;

  my $type = 'message/rfc822';
  if ($part) {
    my $parsed = $Self->fill_messages($msgid);
    $type = find_type($parsed->{$msgid}{bodyStructure}, $part);
  }

  my $res = $Self->backend_cmd('imap_getpart', $imapname, $uidvalidity, $uid, $part);

  return ($type, $res->{data});
}

sub create_mailboxes {
  my $Self = shift;
  my $new = shift;
  my $idmap = shift;

  return ({}, {}) unless keys %$new;

  # XXX - handle sort order issues - it may actually be necessary to create a folder to get its ID
  # so we know the ID of the next one, and so on.

  $Self->begin();
  my %todo;
  my %notcreated;
  my @list = keys %$new;
  my %fromthis;
  while (my $cid = shift @list) {
    my $mailbox = $new->{$cid};
    my %bad;

    unless (defined $mailbox->{name} and $mailbox->{name} ne '') {
      $bad{name} = 1;
    }

    my $encname = eval { encode('IMAP-UTF-7', $mailbox->{name}) };
    unless (defined $encname) {
      $bad{name} = 1;
    }

    # Replace hierarchy separator in the encoded name so IMAP doesn't
    # interpret it as a path delimiter.  Cyrus uses ^ as the replacement.
    if (defined $encname) {
      my ($sep) = $Self->dbh->selectrow_array("SELECT sep FROM ifolders ORDER BY ifolderid");
      if ($sep && $encname =~ /\Q$sep\E/) {
        $encname =~ s/\Q$sep\E/^/g;
      }
    }

    my %immutable = (
      id => $cid,  # XXX: allows re-creating with old ID, which allows UNDO but is tricky
      totalEmails => 0,
      unreadEmails => 0,
      totalThreads => 0,
      unreadThreads => 0,
      myRights => {
        mayAddItems => $JSON::true,
        mayCreateChild => $JSON::true,
        mayDelete => $JSON::true,
        mayReadItems => $JSON::true,
        mayRemoveItems => $JSON::true,
        mayRename => $JSON::true,
        maySetKeywords => $JSON::true,
        maySetSeen => $JSON::true,
        maySubmit => $JSON::true,
        mayAdmin => $JSON::true,
      },
    );

    for my $key (keys %immutable) {
      next unless exists $mailbox->{$key};
      if (ref($immutable{$key}) eq 'HASH') {
        if (ref($mailbox->{$key}) eq 'HASH') {
          for my $sub (keys %{$mailbox->{$key}}) {
            unless (exists $immutable{$key}{$sub}) {
              $bad{"$key/$sub"} = 1;
              next;
            }
            my $got = $mailbox->{$key}{$sub};
            my $want = $immutable{$key}{$sub};
            if (ref($want) && "$want" =~ /^[01]$/) {
              $bad{"$key/$sub"} = 1 if !!$got != !!$want;
            } else {
              $bad{"$key/$sub"} = 1 if "$got" ne "$want";
            }
          }
        }
        else {
          $bad{$key} = 1;
        }
      }
      elsif (ref($immutable{$key}) && "$immutable{$key}" =~ /^[01]$/) {
        $bad{$key} = 1 if !!$mailbox->{$key} != !!$immutable{$key};
      }
      elsif (ref($mailbox->{$key}) || "$immutable{$key}" ne "$mailbox->{$key}") {
        $bad{$key} = 1;
      }
    }

    my $parentid = $idmap->($mailbox->{parentId});

    if ($parentid) {
      if ($parentid =~ m/^\#(.*)/) {
        if ($todo{$1}) {
          my $sep = $todo{$1}[1];
          $todo{$cid} = [$todo{$1}[0] . $sep . $encname, $sep] unless %bad;
        }
        else {
          # try later
          push @list, $cid;
          next;
        }
      }
      else {
        my $parent = $Self->dgetone('ifolders', { jmailboxid => $parentid }, 'imapname,sep');
        # XXX - check "mailCreateChild" on parent mailbox
        if ($parent) {
          $todo{$cid} = [$parent->{imapname} . $parent->{sep} . $encname, $parent->{sep}] unless %bad;
        }
        else {
          $bad{parentId} = 1;
        }
      }
    }
    elsif (not %bad) {
      # will probably get INBOX - but meh, close enough.  Sync will fix it if needed.  Better
      # would be to use namespace to lift it when we lift the prefix
      # DBNOTE: this one is a little weird with use or ORDER BY
      my ($sep) = $Self->dbh->selectrow_array("SELECT sep FROM ifolders ORDER BY ifolderid");
      $sep //= $Self->dgetfield('iserver', {}, 'imapSep') // '/';
      my $prefix = $Self->dgetfield('iserver', {}, 'imapPrefix') // '';
      $todo{$cid} = [$prefix . $encname, $sep];
    }

    if (%bad) {
      $notcreated{$cid} = { type => "invalidProperties", properties => [sort keys %bad] };
    }
  }

  $Self->commit();

  my %createmap;
  foreach my $cid (sort { $todo{$a}[0] cmp $todo{$b}[0] } keys %todo) {
    my ($imapname, $sep) = @{$todo{$cid}};
    # XXX - check if already exists?
    my $res = $Self->backend_cmd('create_mailbox', $imapname);
    if ($res->[1] eq 'ok') {
      my $mailbox = $new->{$cid};
      my $status = $res->[2];
      my $parentid = $idmap->($mailbox->{parentId});
      if (defined $parentid and $parentid =~ m/^\#(.*)/) {
        if ($createmap{$1}) {
          $parentid = $createmap{$1}{id};
        }
        else {
          $notcreated{$cid} = {type => 'invalidResultReference', description => "missing create for parentId"};
          next;
        }
      }
      # yeah, I don't care so much here about the cost of lots of transactions, creating a mailbox is expensive
      $Self->begin();
      my $jmailboxid = new_uuid_string();
      my $ifolderid = $Self->dinsert('ifolders', {
        sep => $sep,
        imapname => $imapname,
        label => $mailbox->{name},
        jmailboxid => $jmailboxid,
        uidvalidity => $status->{uidvalidity},
        uidnext => $status->{uidnext},
        uidfirst => $status->{uidnext},
        highestmodseq => $status->{highestmodseq},
      });
      $Self->dmake('jmailboxes', {
        name => $mailbox->{name},
        jmailboxid => $jmailboxid,
        sortOrder => $mailbox->{sortOrder} // 0,
        parentId => $parentid,
        role => $mailbox->{role},
        # RFC 8621 S2: isSubscribed has no default; a new mailbox the
        # client did not ask about is subscribed, as sync treats them.
        isSubscribed => (!exists $mailbox->{isSubscribed} || $mailbox->{isSubscribed}) ? 1 : 0,
        (map { $_ => 1 } qw(mayReadItems mayAddItems mayRemoveItems maySetSeen
                            maySetKeywords mayCreateChild mayRename mayDelete
                            maySubmit mayAdmin)),
      }, 'jnoncountsmodseq');

      $Self->commit();

      $createmap{$cid} = { id => $jmailboxid };
    }
    else {
      $notcreated{$cid} = {type => 'internalError', description => $res->[2]};
    }
  }

  return (\%createmap, \%notcreated);
}

sub update_mailboxes {
  my $Self = shift;
  my $update = shift;
  my $idmap = shift;

  return ({}, {}) unless %$update;

  $Self->begin();

  my %changed;
  my %notchanged;
  my %namemap;
  my %newparent;
  # XXX - reorder the crap out of this if renaming multiple mailboxes due to deep rename
  foreach my $jid (keys %$update) {
    my $mailbox = $update->{$jid};
    my %bad;

    my $data = $Self->dgetone('jmailboxes', {jmailboxid => $jid, active => 1});
    my $old = $Self->dgetone('ifolders', { jmailboxid => $jid }, 'imapname,ifolderid');
    unless ($data and $old) {
      $notchanged{$jid} = { type => 'notFound' };
      next;
    }

    my %immutable = (
      id => $jid,
      totalEmails => $data->{totalEmails},
      unreadEmails => $data->{unreadEmails},
      totalThreads => $data->{totalThreads},
      unreadThreads => $data->{unreadThreads},
      myRights => {
        map { $_ => $JSON::true } grep { $data->{$_} } qw(mayAddItems mayCreateChild mayDelete mayReadItems mayRemoveItems mayRename maySetKeywords maySetSeen maySubmit mayAdmin),
      },
    );

    for my $key (keys %immutable) {
      next unless exists $mailbox->{$key};
      if (ref($immutable{$key}) eq 'HASH') {
        if (ref($mailbox->{$key}) eq 'HASH') {
          for my $sub (keys %{$mailbox->{$key}}) {
            unless (exists $immutable{$key}{$sub}) {
              $bad{"$key/$sub"} = 1;
              next;
            }
            my $got = $mailbox->{$key}{$sub};
            my $want = $immutable{$key}{$sub};
            if (ref($want) && "$want" =~ /^[01]$/) {
              $bad{"$key/$sub"} = 1 if !!$got != !!$want;
            } else {
              $bad{"$key/$sub"} = 1 if "$got" ne "$want";
            }
          }
        }
        else {
          $bad{$key} = 1;
        }
      }
      elsif (ref($immutable{$key}) && "$immutable{$key}" =~ /^[01]$/) {
        $bad{$key} = 1 if !!$mailbox->{$key} != !!$immutable{$key};
      }
      elsif (ref($mailbox->{$key}) || "$immutable{$key}" ne "$mailbox->{$key}") {
        $bad{$key} = 1;
      }
    }

    for my $key (keys %$mailbox) {
      if ($key =~ m{(.*)/(.*)}) {
        # XXX - multi-depth
        $data->{$1}{$2} = $mailbox->{$key};
      }
      else {
        $data->{$key} = $mailbox->{$key};
      }
    }

    my $encname = eval { encode('IMAP-UTF-7', $data->{name}) };
    unless (defined $encname) {
      $bad{name} = 1;
      $encname = ''; # quiet warnings
    }

    my $parentid = $data->{parentId};
    if (defined $data->{parentId}) {
      $parentid = $idmap->($parentid);
      my $parent = $Self->dgetone('ifolders', { jmailboxid => $parentid }, 'imapname,sep');
      warn "PARENT: " . Dumper($parent, $parentid, $data);
      # RFC 8621 S2: "There MUST NOT be a loop" -- the new parent may not be
      # this mailbox or any of its descendants, counting earlier updates in
      # this same request.
      my %seen;
      for (my $pid = $parentid; $pid && !$seen{$pid}++;
           $pid = exists $newparent{$pid} ? $newparent{$pid}
                : $Self->dgetfield('jmailboxes', { jmailboxid => $pid }, 'parentId')) {
        if ($pid eq $jid) {
          $bad{parentId} = 1;
          last;
        }
      }
      if ($bad{parentId}) {
        # already rejected
      }
      elsif ($parent) {
        $namemap{$old->{imapname}} = [$parent->{imapname} . $parent->{sep} . $encname, $jid, $old->{ifolderid}];
      }
      else {
        $bad{parentId} = 1;
      }
    }
    else {
      my $prefix = $Self->dgetfield('iserver', {}, 'imapPrefix');
      $prefix = '' unless $prefix;
      $namemap{$old->{imapname}} = [$prefix . $encname, $jid, $old->{ifolderid}];
    }

    if (%bad) {
      $notchanged{$jid} = { type => 'invalidProperties', properties => [sort keys %bad] };
    }
    elsif (exists $mailbox->{parentId}) {
      $newparent{$jid} = $parentid;
    }
  }

  $Self->commit();

  my %toupdate;
  foreach my $oldname (sort keys %namemap) {
    my ($imapname, $jid, $ifolderid) = @{$namemap{$oldname}};
    next if $notchanged{$jid};

    if ($imapname eq $oldname) {
      # no change, yay
      $changed{$jid} = undef;
      next;
    }

    my $res = $Self->backend_cmd('rename_mailbox', $oldname, $imapname);
    if ($res->[1] eq 'ok') {
      $changed{$jid} = undef;
      $toupdate{$jid} = [$imapname, $ifolderid];
    }
    else {
      $notchanged{$jid} = {type => 'serverError', description => $res->[2]};
    }
  }

  if (keys %changed) {
    $Self->begin();
    foreach my $jid (keys %changed) {
      if ($toupdate{$jid}) {
        my ($imapname, $ifolderid) = @{$toupdate{$jid}};
        $Self->dmaybeupdate('ifolders', {imapname => $imapname}, {ifolderid => $ifolderid});
      }
      my $change = $update->{$jid};
      my %changes;
      $changes{name} = $change->{name} if exists $change->{name};
      $changes{parentId} = $idmap->($change->{parentId}) if exists $change->{parentId};
      $changes{sortOrder} = $change->{sortOrder} if exists $change->{sortOrder};
      $changes{role} = $change->{role} if exists $change->{role};
      $changes{isSubscribed} = $change->{isSubscribed} ? 1 : 0 if exists $change->{isSubscribed};
      $Self->dmaybedirty('jmailboxes', \%changes, {jmailboxid => $jid}, 'jnoncountsmodseq') if %changes;
    }
    $Self->commit();
  }

  return (\%changed, \%notchanged);
}

sub deepeq {
  my ($x, $y) = @_;
  # all the undefs
  if (not defined $x or not defined $y) {
    return 1 if (not defined $x and not defined $y);
    return 0;
  }
  # json encoding
  return $json->encode([$x]) eq $json->encode([$y]);
}

sub destroy_mailboxes {
  my $Self = shift;
  my $destroy = shift;
  my $destroyMessages = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my @destroyed;
  my %notdestroyed;
  my %namemap;
  foreach my $jid (@$destroy) {
    my $old = $Self->dgetone('ifolders', { jmailboxid => $jid }, 'imapname,ifolderid');
    if ($old) {
      unless ($destroyMessages) {
        # check if empty
        if ($Self->dcount('imessages', { ifolderid => $old->{ifolderid} })) {
          $notdestroyed{$jid} = { type => 'mailboxHasEmail' };
          next;
        }
      }

      $namemap{$old->{imapname}} = [$jid, $old->{ifolderid}];
    }
    else {
      $notdestroyed{$jid} = {type => 'notFound'};
    }
  }

  # look for children not being deleted
  foreach my $oldname (reverse sort keys %namemap) {
    my ($jid, $ifolderid) = @{$namemap{$oldname}};
    my $children = $Self->dget('jmailboxes', { parentId => $jid, active => 1 }, 'jmailboxid');
    for my $child (@$children) {
      # OK if it's already being destroyed
      next if grep { $child->{jmailboxid} eq $_ and not $notdestroyed{$_} } @$destroy;
      $notdestroyed{$jid} = { type => 'mailboxHasChild' };
      delete $namemap{$oldname};
    }
  }

  $Self->commit();

  # we reverse so we delete children before parents
  my %toremove;
  foreach my $oldname (reverse sort keys %namemap) {
    my ($jid, $ifolderid) = @{$namemap{$oldname}};
    my $res = $Self->backend_cmd('delete_mailbox', $oldname);
    if ($res->[1] eq 'ok') {
      push @destroyed, $jid;
      $toremove{$jid} = $ifolderid;
    }
    else {
      $notdestroyed{$jid} = {type => 'serverError', description => $res->[2]};
    }
  }

  if (keys %toremove) {
    $Self->begin();
    foreach my $jid (sort keys %toremove) {
      my $ifolderid = $toremove{$jid};
      $Self->ddelete('ifolders', {ifolderid => $ifolderid});
      $Self->ddelete('imessages', {ifolderid => $ifolderid});
      my $tocheck = $Self->dget('jmessagemap', {active => 1, jmailboxid => $jid}, 'active,msgid');
      $Self->dmaybedirty('jmailboxes', {active => 0}, {jmailboxid => $jid});
      $Self->dupdate('jmessagemap', {active => 0}, {jmailboxid => $jid});
      # item contains 'msgid' and 'active', precisely what we want to filter on
      for my $item (@$tocheck) {
        if ($Self->dgetone('jmessagemap', $item, 'msgid')) {
          # there's other copies, don't nuke it
          $Self->dupdate('jmessages', {}, $item);
        }
        else {
          $Self->dupdate('jmessages', {active => 0}, $item);
        }
      }
    }
    $Self->commit();
  }

  return (\@destroyed, \%notdestroyed);
}


sub _utcnow {
  my @t = gmtime();
  return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
    $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

# Set scheduleAgent=client on all participants
# so the CalDAV server knows the client is handling scheduling, not the server.
sub _set_schedule_agent_client {
  my ($ev) = @_;
  for my $p (values %{$ev->{participants} // {}}) {
    $p->{scheduleAgent} //= 'client';
  }
}

sub create_calendar_events {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %todo;
  my %createmap;
  my %notcreated;
  my $user_email = lc($Self->get_user()->{email} // '');
  foreach my $cid (sort keys %$new) {
    my $calendar = $new->{$cid};
    # draft-ietf-jmap-calendars S5.9: "The method property MUST NOT be set."
    if (exists $calendar->{method}) {
      $notcreated{$cid} = { type => 'invalidProperties', properties => ['method'] };
      next;
    }
    my @cal_ids = grep { ($calendar->{calendarIds} || {})->{$_} }
                       keys %{$calendar->{calendarIds} || {}};
    if (@cal_ids > 1) {
      $notcreated{$cid} = { type => 'invalidProperties',
        properties => ['calendarIds'],
        description => 'Only one calendar per event is supported' };
      next;
    }
    my ($jcalendarid) = @cal_ids;
    $jcalendarid //= $calendar->{calendarId};  # fallback for old clients
    my $href = $Self->dgetfield('icalendars', { jcalendarid => $jcalendarid }, 'href');
    unless ($href) {
      $notcreated{$cid} = {type => 'notFound', description => "No such calendar on server"};
      next;
    }
    my $uid = $calendar->{uid} // new_uuid_string();

    my $now = _utcnow();
    my %ev = (%$calendar, uid => $uid);
    delete $ev{calendarIds};
    delete $ev{calendarId};
    # S5.9: if omitted the server sets @type, uid and created; on an event
    # this server originates, updated is always the server's time, and a
    # client created later than that is reset with it.
    my %server_set;
    $server_set{uid} = $uid unless defined $calendar->{uid};
    $server_set{'@type'} = $ev{'@type'} = 'Event' unless defined $ev{'@type'};
    $server_set{created} = $ev{created} = $now unless defined $ev{created};
    my $organizer = lc($ev{organizerCalendarAddress} // '') =~ s{^mailto:}{}r;
    if (!defined $ev{organizerCalendarAddress} || $organizer eq $user_email) {
      $server_set{updated} = $ev{updated} = $now;
      $server_set{created} = $ev{created} = $now if $ev{created} gt $now;
    }
    else {
      $ev{updated} //= $now;
    }
    my $no_sched = defined $ev{sendSchedulingMessages} ? !$ev{sendSchedulingMessages} : 0;
    delete $ev{sendSchedulingMessages};
    if ($no_sched) {
      $ev{_no_schedule} = 1;
      _set_schedule_agent_client(\%ev);
    }
    $todo{$cid} = [$href, \%ev];

    # RFC 8620 S5.3: created reports what the server set or defaulted
    $createmap{$cid} = { id => $uid, %server_set };
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    eval { $Self->backend_cmd('new_event', @{$todo{$cid}}) };
    if ($@) {
      delete $createmap{$cid};
      $notcreated{$cid} = { type => 'serverFail', description => "$@" };
    }
  }

  return (\%createmap, \%notcreated);
}

sub update_calendar_events {
  my $Self = shift;
  my $update = shift;
  my $idmap = shift;

  return ({}, {}) unless %$update;

  $Self->begin();

  my %todo;         # href => [uid, event_data]
  my %todo_occurrence;  # href => [[recurrenceId, uid_key, patch], ...]
  my %todo_move;    # old_href => {new_cal_href, uid}
  my %changed;
  my %notchanged;
  foreach my $uid (keys %$update) {
    my $calendar = $update->{$uid};

    if (exists $calendar->{method}) {
      $notchanged{$uid} = { type => 'invalidProperties', properties => ['method'] };
      next;
    }

    if ($uid =~ m{^([^/]+)/(.+)$}) {
      my ($master_uid, $recurrence_id) = ($1, $2);
      my $href = $Self->dgetfield('ievents', { uid => $master_uid }, 'href');
      unless ($href) {
        $notchanged{$uid} = {type => 'notFound', description => "No such calendar event"};
        next;
      }
      my %patch = %$calendar;
      delete @patch{qw(calendarIds calendarId)};
      $patch{updated} //= _utcnow();
      my $no_sched_occ = defined $patch{sendSchedulingMessages} ? !$patch{sendSchedulingMessages} : 0;
      delete $patch{sendSchedulingMessages};
      $patch{_no_schedule} = 1 if $no_sched_occ;
      push @{$todo_occurrence{$href}}, [$recurrence_id, $uid, \%patch];
      $changed{$uid} = undef;
      next;
    }

    my $href = $Self->dgetfield('ievents', { uid => $uid }, 'href');
    unless ($href) {
      $notchanged{$uid} = {type => 'notFound', description => "No such event on server"};
      next;
    }

    if (my $cids = $calendar->{calendarIds}) {
      my @active = grep { $cids->{$_} } keys %$cids;
      if (@active > 1) {
        $notchanged{$uid} = { type => 'invalidProperties',
          properties => ['calendarIds'],
          description => 'Only one calendar per event is supported' };
        next;
      }
      if (@active == 1) {
        my $new_jcal_id = $active[0];
        my $new_ical = $Self->dgetone('icalendars', {jcalendarid => $new_jcal_id});
        unless ($new_ical) {
          $notchanged{$uid} = {type => 'notFound', description => 'Target calendar not found'};
          next;
        }
        my $cur_icalid = $Self->dgetfield('ievents', {href => $href}, 'icalendarid');
        if (defined $cur_icalid && $new_ical->{icalendarid} != $cur_icalid) {
          $todo_move{$href} = {new_cal_href => $new_ical->{href}, uid => $uid};
        }
      }
    }
    my %ev = %$calendar;
    delete $ev{calendarIds};
    delete $ev{calendarId};
    $ev{updated} //= _utcnow();
    my $no_sched = defined $ev{sendSchedulingMessages} ? !$ev{sendSchedulingMessages} : 0;
    delete $ev{sendSchedulingMessages};
    if ($no_sched) {
      $ev{_no_schedule} = 1;
      _set_schedule_agent_client(\%ev);
    }
    $todo{$href} = [$uid, \%ev];

    $changed{$uid} = undef;
  }

  $Self->commit();

  foreach my $href (sort keys %todo_move) {
    my $info = $todo_move{$href};
    my $uid  = $info->{uid};
    my $new_href = eval { $Self->backend_cmd('move_event', $href, $info->{new_cal_href}) };
    if ($@) {
      $notchanged{$uid} = {type => 'serverFail', description => "$@"};
      delete $changed{$uid};
      delete $todo{$href};
      next;
    }
    if ($new_href && $new_href ne $href && exists $todo{$href}) {
      $todo{$new_href} = delete $todo{$href};
    }
  }

  foreach my $href (sort keys %todo) {
    my ($uid, $ev) = @{$todo{$href}};
    eval { $Self->backend_cmd('update_event', $href, $ev) };
    if ($@) {
      $notchanged{$uid} = { type => 'serverFail', description => "$@" };
      delete $changed{$uid};
    }
  }
  foreach my $href (sort keys %todo_occurrence) {
    for my $triple (@{$todo_occurrence{$href}}) {
      my ($recurrence_id, $uid_key, $patch) = @$triple;
      eval { $Self->backend_cmd('update_event_occurrence', $href, $recurrence_id, $patch) };
      if ($@) {
        $notchanged{$uid_key} = { type => 'serverFail', description => "$@" };
        delete $changed{$uid_key};
      }
    }
  }

  return (\%changed, \%notchanged);
}

sub destroy_calendar_events {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my %todo;
  my %todo_occurrence;  # href => [recurrenceId, ...]
  my @destroyed;
  my %notdestroyed;
  foreach my $uid (@$destroy) {
    if ($uid =~ m{^([^/]+)/(.+)$}) {
      my ($master_uid, $recurrence_id) = ($1, $2);
      my $href = $Self->dgetfield('ievents', { uid => $master_uid }, 'href');
      unless ($href) {
        $notdestroyed{$uid} = {type => 'notFound', description => "No such calendar event"};
        next;
      }
      push @{$todo_occurrence{$href}}, $recurrence_id;
      push @destroyed, $uid;
      next;
    }

    my $href = $Self->dgetfield('ievents', { uid => $uid }, 'href');
    unless ($href) {
      $notdestroyed{$uid} = {type => 'notFound', description => "No such event on server"};
      next;
    }

    $todo{$href} = $uid;
    push @destroyed, $uid;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('delete_event', $href);
  }

  if (%todo) {
    $Self->begin();
    for my $href (sort keys %todo) {
      $Self->delete_event(undef, $todo{$href});
    }
    $Self->commit();
  }

  foreach my $href (sort keys %todo_occurrence) {
    for my $recurrence_id (@{$todo_occurrence{$href}}) {
      $Self->backend_cmd('update_event_occurrence', $href, $recurrence_id, undef);
    }
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_contact_groups {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %todo;
  my %createmap;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $contact = $new->{$cid};
    #my $href = $Self->dgetfield('iaddressbooks', { iaddressbookid => $contact->{addressbookId} }, 'href');
    my $href = $Self->dgetfield('iaddressbooks', {}, 'href');
    unless ($href) {
      $notcreated{$cid} = {type => 'notFound', description => "No such addressbook on server"};
      next;
    }
    my $name = $contact->{name} || 'Unknown';

    my $uid = new_uuid_string();
    my $card = {
      uid => "urn:uuid:$uid",
      kind => 'group',
      name => { full => $name },
    };
    if (exists $contact->{contactIds}) {
      my %members;
      $members{"urn:uuid:$_"} = $JSON::true for @{$contact->{contactIds}};
      $card->{members} = \%members;
    }

    $todo{$cid} = [$href, $card];

    $createmap{$cid} = { id => $uid };
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    # XXX - on error?  Should remove $createmap{$cid} and set $notcreated{$cid}
    $Self->backend_cmd('new_card', @{$todo{$cid}});
  }

  return (\%createmap, \%notcreated);
}

sub update_contact_groups {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();

  my %todo;
  my %changed;
  my %notchanged;
  foreach my $carduid (keys %$changes) {
    my $contact = $changes->{$carduid};
    my $old = $Self->dgetone('icards', { kind => 'group', uid => $carduid }, 'href');
    unless ($old) {
      $notchanged{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    my $raw_vcf = $Self->read_card_vcf($carduid) // '';
    my $card = vcard_to_jscontact($raw_vcf);
    unless ($card) {
      $notchanged{$carduid} = {type => 'parseError', description => "Could not parse existing card"};
      next;
    }
    $card->{kind} = 'group';
    $card->{name}{full} = $contact->{name} if exists $contact->{name};
    if (exists $contact->{contactIds}) {
      my @ids = map { $idmap->($_) } @{$contact->{contactIds}};
      my %members;
      $members{"urn:uuid:$_"} = $JSON::true for @ids;
      $card->{members} = \%members;
    }

    $todo{$old->{href}} = $card;
    $changed{$carduid} = undef;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('update_card', $href, $todo{$href});
  }

  return (\%changed, \%notchanged);
}

sub destroy_contact_groups {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my %todo;
  my @destroyed;
  my %notdestroyed;
  foreach my $carduid (@$destroy) {
    my $old = $Self->dgetone('icards', { kind => 'group', uid => $carduid }, 'href');
    unless ($old) {
      $notdestroyed{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    $todo{$old->{href}} = 1;
    push @destroyed, $carduid;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('delete_card', $href);
  }

  return (\@destroyed, \%notdestroyed);
}

# Bridge old custom contact format to JSContact
sub _contact_to_jscontact {
  my ($uid, $contact) = @_;

  my $card = {
    uid => "urn:uuid:$uid",
    name => {},
  };

  # Name components
  my @components;
  push @components, { kind => 'surname', value => $contact->{lastName} } if $contact->{lastName};
  push @components, { kind => 'given', value => $contact->{firstName} } if $contact->{firstName};
  push @components, { kind => 'title', value => $contact->{prefix} } if $contact->{prefix};
  $card->{name}{components} = \@components if @components;
  $card->{name}{full} = join(' ', grep { $_ } $contact->{prefix}, $contact->{firstName}, $contact->{lastName}) || 'Unknown';

  # Organization
  if ($contact->{company}) {
    my $org = { name => $contact->{company} };
    $org->{units} = [{ name => $contact->{department} }] if $contact->{department};
    $card->{organizations} = { o1 => $org };
  }

  # Emails
  if ($contact->{emails} && @{$contact->{emails}}) {
    my %emails;
    my $n = 1;
    for my $em (@{$contact->{emails}}) {
      $emails{"e$n"} = { address => $em->{value} };
      $n++;
    }
    $card->{emails} = \%emails;
  }

  # Phones
  if ($contact->{phones} && @{$contact->{phones}}) {
    my %phones;
    my $n = 1;
    for my $ph (@{$contact->{phones}}) {
      $phones{"p$n"} = { number => $ph->{value} };
      $n++;
    }
    $card->{phones} = \%phones;
  }

  # Nickname, birthday, notes
  if ($contact->{nickname}) {
    $card->{nicknames} = { n1 => { name => $contact->{nickname} } };
  }
  if ($contact->{birthday} && $contact->{birthday} ne '0000-00-00') {
    $card->{anniversaries} = { b1 => { kind => 'birth', date => $contact->{birthday} } };
  }
  if ($contact->{notes}) {
    $card->{notes} = { n1 => { note => $contact->{notes} } };
  }

  return $card;
}

sub _apply_contact_changes {
  my ($card, $contact) = @_;

  # Apply each field that exists in the change set
  if (exists $contact->{lastName} || exists $contact->{firstName} || exists $contact->{prefix}) {
    my @components;
    my $ln = exists $contact->{lastName} ? $contact->{lastName} : _get_name_component($card, 'surname');
    my $fn = exists $contact->{firstName} ? $contact->{firstName} : _get_name_component($card, 'given');
    my $pf = exists $contact->{prefix} ? $contact->{prefix} : _get_name_component($card, 'title');
    push @components, { kind => 'surname', value => $ln } if $ln;
    push @components, { kind => 'given', value => $fn } if $fn;
    push @components, { kind => 'title', value => $pf } if $pf;
    $card->{name}{components} = \@components;
    $card->{name}{full} = join(' ', grep { $_ } $pf, $fn, $ln) || 'Unknown';
  }
  if (exists $contact->{company}) {
    my $org = $card->{organizations} ? (values %{$card->{organizations}})[0] : {};
    $org->{name} = $contact->{company};
    $org->{units} = [{ name => $contact->{department} }] if exists $contact->{department};
    $card->{organizations} = { o1 => $org };
  }
  if (exists $contact->{nickname}) {
    $card->{nicknames} = $contact->{nickname} ? { n1 => { name => $contact->{nickname} } } : undef;
  }
  if (exists $contact->{birthday}) {
    if ($contact->{birthday} && $contact->{birthday} ne '0000-00-00') {
      $card->{anniversaries} = { b1 => { kind => 'birth', date => $contact->{birthday} } };
    } else {
      delete $card->{anniversaries};
    }
  }
  if (exists $contact->{notes}) {
    $card->{notes} = $contact->{notes} ? { n1 => { note => $contact->{notes} } } : undef;
  }
}

sub _get_name_component {
  my ($card, $kind) = @_;
  return '' unless $card->{name} && $card->{name}{components};
  for my $c (@{$card->{name}{components}}) {
    return $c->{value} if $c->{kind} eq $kind;
  }
  return '';
}

sub create_contacts {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %createmap;
  my %notcreated;
  my %todo;
  foreach my $cid (keys %$new) {
    my $contact = $new->{$cid};
    my $abookhref = $Self->dgetfield('iaddressbooks', {}, 'href');
    unless ($abookhref) {
      $notcreated{$cid} = {type => 'notFound', description => "No such addressbook on server"};
      next;
    }
    my $uid = new_uuid_string();
    my $card = _contact_to_jscontact($uid, $contact);

    $todo{$cid} = [$abookhref, $card];

    $createmap{$cid} = { id => $uid };
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    # XXX - on error?  Should remove $createmap{$cid} and set $notcreated{$cid}
    $Self->backend_cmd('new_card', @{$todo{$cid}});
  }

  return (\%createmap, \%notcreated);
}

sub update_contacts {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();

  my %todo;
  my %changed;
  my %notchanged;
  foreach my $carduid (keys %$changes) {
    my $contact = $changes->{$carduid};
    my $old = $Self->dgetone('icards', { uid => $carduid }, 'href');
    unless ($old) {
      $notchanged{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    my $raw_vcf = $Self->read_card_vcf($carduid) // '';
    my $card = vcard_to_jscontact($raw_vcf);
    unless ($card) {
      $notchanged{$carduid} = {type => 'parseError', description => "Could not parse existing card"};
      next;
    }
    # Apply changes from the old custom format onto the JSContact card
    _apply_contact_changes($card, $contact);

    $todo{$old->{href}} = $card;
    $changed{$carduid} = undef;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('update_card', $href, $todo{$href});
  }

  return (\%changed, \%notchanged);
}

# A ContactCard id is its uid without any urn:uuid: prefix (see set_card);
# icards keeps the uid as the vCard has it.
sub _icard_for {
  my ($Self, $id, $fields) = @_;
  return $Self->dgetone('icards', { uid => $id }, $fields)
      // $Self->dgetone('icards', { uid => "urn:uuid:$id" }, $fields);
}

sub destroy_contacts {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  my %todo;
  my @destroyed;
  my %notdestroyed;
  foreach my $carduid (@$destroy) {
    $Self->begin();
    my $old = $Self->_icard_for($carduid, 'href,iaddressbookid');
    unless ($old) {
      $Self->commit();
      $notdestroyed{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    my $jaddressbookid = $Self->dgetfield('iaddressbooks', { iaddressbookid => $old->{iaddressbookid} }, 'jaddressbookid');
    $Self->unlink_jcontact_payload($carduid);
    $Self->dmaybedirty('jcontacts', { active => 0 }, { contactuid => $carduid, jaddressbookid => $jaddressbookid });
    $Self->commit();
    $todo{$old->{href}} = 1;
    push @destroyed, $carduid;
  }

  foreach my $href (sort keys %todo) {
    eval { $Self->backend_cmd('delete_card', $href) };
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_contacts_jscontact {
  my $Self = shift;
  my $new  = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();
  my $iaddressbooks = $Self->dget('iaddressbooks', {}, 'iaddressbookid,jaddressbookid,href');
  $Self->commit();

  my %href_by_jab = map { $_->{jaddressbookid} => $_->{href} } @$iaddressbooks;
  my $default_href = $iaddressbooks->[0]{href};

  my %createmap;
  my %notcreated;
  my %seen_uid;

  for my $cid (sort keys %$new) {
    my $card = { %{ $new->{$cid} } };  # shallow copy so we don't modify caller's data

    # Resolve addressBookIds to a CardDAV href
    my $abookhref = $default_href;
    if (exists $card->{addressBookIds}) {
      my $abids = delete $card->{addressBookIds};
      # RFC 9610 S3: each value "MUST be true", a card "MUST belong to at
      # least one AddressBook", and an unknown id is invalid (RFC 8620 S5.3).
      unless (ref $abids eq 'HASH' && %$abids
              && !grep { !(JSON::is_bool($abids->{$_}) && $abids->{$_}) || !$href_by_jab{$_} } keys %$abids) {
        $notcreated{$cid} = { type => 'invalidProperties', properties => ['addressBookIds'] };
        next;
      }
      my @active = grep { $abids->{$_} } keys %$abids;
      if (@active > 1) {
        $notcreated{$cid} = { type => 'invalidProperties',
          properties => ['addressBookIds'],
          description => 'Only one address book per card is supported' };
        next;
      }
      my ($jab_id) = @active;
      $abookhref = $href_by_jab{$jab_id} // $default_href if $jab_id;
    }

    unless ($abookhref) {
      $notcreated{$cid} = { type => 'notFound', description => 'No addressbook on server' };
      next;
    }
    unless (($card->{'@type'} // '') eq 'Card') {
      $notcreated{$cid} = { type => 'invalidProperties',
        properties => ['@type'],
        description => '@type must be "Card"' };
      next;
    }
    unless (($card->{version} // '') =~ /^[12]\.0$/) {
      $notcreated{$cid} = { type => 'invalidProperties',
        properties => ['version'],
        description => 'version must be a registered JSContact version ("1.0" or "2.0")' };
      next;
    }
    my $client_uid = defined $card->{uid};
    # RFC 9610 S3: "there MUST NOT be more than one ContactCard with the
    # same uid in an Account".
    if ($client_uid) {
      my $bare = $card->{uid} =~ s/^urn:uuid://r;
      $Self->begin();
      my $taken = $Self->dgetfield('jcontacts', { contactuid => $bare, active => 1 }, 'contactuid')
               // $Self->_icard_for($bare, 'href');
      $Self->commit();
      if ($taken || $seen_uid{$bare}++) {
        $notcreated{$cid} = { type => 'invalidProperties', properties => ['uid'],
          description => 'a ContactCard with this uid already exists' };
        next;
      }
    }
    my $uid = $card->{uid} // new_uuid_string();
    $card->{uid} = $uid;
    eval { $Self->backend_cmd('new_card', $abookhref, $card) };
    if ($@) {
      $notcreated{$cid} = { type => 'serverFail', description => "$@" };
      next;
    }
    # The id is the uid without its urn:uuid: prefix, as set_card stores it
    # and ContactCard/get, /set and /changes report it.
    $createmap{$cid} = { id => ($uid =~ s/^urn:uuid://r) };
    $createmap{$cid}{uid} = $uid unless $client_uid;
  }

  return (\%createmap, \%notcreated);
}

sub update_contacts_jscontact {
  my $Self  = shift;
  my $changes = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();
  my $iaddressbooks = $Self->dget('iaddressbooks', {}, 'iaddressbookid,jaddressbookid,href');
  $Self->commit();
  my %href_by_jab = map { $_->{jaddressbookid} => $_->{href} } @$iaddressbooks;
  my %jab_by_href = map { $_->{href} => $_->{jaddressbookid} } @$iaddressbooks;
  my %iab_by_jab  = map { $_->{jaddressbookid} => $_->{iaddressbookid} } @$iaddressbooks;

  my %changed;
  my %notchanged;

  for my $carduid (sort keys %$changes) {
    my $patch = { %{ $changes->{$carduid} } };  # shallow copy

    $Self->begin();
    my $icard = $Self->_icard_for($carduid, 'href,iaddressbookid');
    my $jcontact = $Self->dgetone('jcontacts', { contactuid => $carduid }, 'jaddressbookid');
    $Self->commit();

    unless ($icard) {
      $notchanged{$carduid} = { type => 'notFound', description => 'No such card on server' };
      next;
    }

    # Handle addressBookIds change: MOVE card to new collection
    if (exists $patch->{addressBookIds}) {
      my $abids = delete $patch->{addressBookIds};
      unless (ref $abids eq 'HASH' && %$abids
              && !grep { !(JSON::is_bool($abids->{$_}) && $abids->{$_}) || !$href_by_jab{$_} } keys %$abids) {
        $notchanged{$carduid} = { type => 'invalidProperties', properties => ['addressBookIds'] };
        next;
      }
      my @active = $abids ? grep { $abids->{$_} } keys %$abids : ();
      if (@active > 1) {
        $notchanged{$carduid} = { type => 'invalidProperties',
          properties => ['addressBookIds'],
          description => 'Only one address book per card is supported' };
        next;
      }
      my ($new_jab_id) = @active;
      my $new_href = $new_jab_id ? $href_by_jab{$new_jab_id} : undef;
      unless ($new_href) {
        $notchanged{$carduid} = { type => 'notFound', description => 'No such address book' };
        next;
      }
      my $old_collection = $icard->{href};
      $old_collection =~ s{/[^/]+$}{};
      if ($old_collection ne $new_href) {
        eval { $Self->backend_cmd('move_card', $icard->{href}, $new_href) };
        if ($@) {
          $notchanged{$carduid} = { type => 'serverFail', description => "$@" };
          next;
        }
        # Derive new href: same filename, new collection
        (my $filename = $icard->{href}) =~ s{.*/}{};
        my $new_card_href = "$new_href/$filename";
        $new_href =~ s{/$}{};
        $Self->begin();
        $Self->dmaybeupdate('icards',
          { href => $new_card_href, iaddressbookid => $iab_by_jab{$new_jab_id} },
          { href => $icard->{href} });
        $Self->dmaybeupdate('jcontacts',
          { jaddressbookid => $new_jab_id },
          { contactuid => $carduid });
        $Self->commit();
        $icard->{href} = $new_card_href;
      }
    }

    if (%$patch) {
      # Parse existing vCard to JSContact, apply remaining patch fields, write back
      # the vCard is filed under its uid, which may carry urn:uuid:
      my $raw_vcf = $Self->read_card_vcf($carduid)
                 // $Self->read_card_vcf("urn:uuid:$carduid") // '';
      my $card = vcard_to_jscontact($raw_vcf);
      unless ($card) {
        $notchanged{$carduid} = { type => 'serverFail', description => 'Could not parse existing card' };
        next;
      }

      # Apply JSContact-format patch (shallow merge of top-level keys)
      for my $key (keys %$patch) {
        if (defined $patch->{$key}) {
          $card->{$key} = $patch->{$key};
        } else {
          delete $card->{$key};
        }
      }

      eval { $Self->backend_cmd('update_card', $icard->{href}, $card) };
      if ($@) {
        $notchanged{$carduid} = { type => 'serverFail', description => "$@" };
        next;
      }
    }

    $changed{$carduid} = undef;
  }

  return (\%changed, \%notchanged);
}

# RFC 8621 S7: the envelope for a submission that gives none.
sub _generate_envelope {
  my $rfc822 = shift;
  my $email = Email::Simple->new($rfc822 // '');
  my $addrs = sub {
    map { @{ Data::JSEmail::asAddresses($_) || [] } } $email->header_raw($_[0]);
  };
  my ($from) = ($addrs->('Sender'), $addrs->('From'));
  my (%seen, @rcpt);
  for my $addr (map { $addrs->($_) } qw(To Cc Bcc)) {
    next unless defined $addr->{email} && !$seen{lc $addr->{email}}++;
    push @rcpt, { email => $addr->{email}, parameters => undef };
  }
  return {
    mailFrom => { email => ($from ? $from->{email} : ''), parameters => undef },
    rcptTo   => \@rcpt,
  };
}

# FUTURERELEASE (RFC 4865): the proxy holds the message itself and sends it
# when due (see send_due), for up to maxDelayedSend.
require JMAP::Capabilities;

# The release time a mailFrom's parameters ask for: (undef) for none,
# (epoch) for a hold, or (undef, $why) when the parameters are not ones we
# support or hold too long.
sub _release_time {
  my ($params, $now) = @_;
  return () unless defined $params;
  return (undef, 'parameters must be an object') unless ref $params eq 'HASH';
  my %p = map { uc($_) => $params->{$_} } keys %$params;
  my @other = grep { !/^HOLD(?:FOR|UNTIL)$/ } keys %p;
  return (undef, "unsupported MAIL FROM parameter @other") if @other;
  return (undef, 'HOLDFOR and HOLDUNTIL together') if keys %p > 1;
  my $when;
  if (defined $p{HOLDFOR}) {
    return (undef, 'bad HOLDFOR') unless ($p{HOLDFOR} // '') =~ /^[1-9]\d{0,8}$/;
    $when = $now + $p{HOLDFOR};
  }
  elsif (defined $p{HOLDUNTIL}) {
    $when = str2time($p{HOLDUNTIL});
    return (undef, 'bad HOLDUNTIL') unless defined $when;
  }
  else {
    return ();
  }
  return (undef, 'hold is longer than maxDelayedSend')
    if $when > $now + $JMAP::Capabilities::MAX_DELAYED_SEND;
  return ($when);
}

# RFC 8621 S7: "The server MUST remove any Bcc header field present on the
# message during delivery."
sub _strip_bcc {
  my $rfc822 = shift;
  my $email = Email::Simple->new($rfc822);
  return $rfc822 unless defined $email->header_raw('Bcc');
  $email->header_set('Bcc');
  return $email->as_string;
}

# The envelope as given to SMTP: the hold parameters are ours, not the
# submission server's.
sub _smtp_envelope {
  my $envelope = shift;
  return { %$envelope, mailFrom => { %{$envelope->{mailFrom}}, parameters => undef } };
}

sub create_submissions {
  my $Self = shift;
  my $new = shift;
  my $idmap = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %createmap;
  my %notcreated;
  my $now = time();
  # Validate each submission and settle its envelope before anything is sent.
  my %ready;   # cid => [msgid, thrid, envelope, release]
  foreach my $cid (sort keys %$new) {
    my $sub = $new->{$cid};
    my $msgid = $idmap->($sub->{emailId} // '');
    my $thrid = $msgid && $Self->dgetfield('jmessages', { msgid => $msgid, active => 1 }, 'thrid');
    unless ($thrid) {
      $notcreated{$cid} = { type => 'invalidProperties', properties => ['emailId'],
                            description => 'no such Email' };
      next;
    }
    # RFC 8621 S7: sendAt and undoStatus are server-set on create
    if (my @bad = grep { exists $sub->{$_} } qw(sendAt undoStatus deliveryStatus dsnBlobIds mdnBlobIds threadId)) {
      $notcreated{$cid} = { type => 'invalidProperties', properties => \@bad };
      next;
    }
    my $envelope = $sub->{envelope};
    my $release;
    if (defined $envelope) {
      my @rcpt = ref $envelope eq 'HASH' && ref $envelope->{rcptTo} eq 'ARRAY' ? @{$envelope->{rcptTo}} : ();
      my $from = ref $envelope eq 'HASH' ? $envelope->{mailFrom} : undef;
      # The only parameters are RFC 4865's HOLDFOR/HOLDUNTIL on mailFrom,
      # which the proxy honours itself (maxDelayedSend); no RCPT TO ones
      my ($when, $why) = ref $from eq 'HASH' ? _release_time($from->{parameters}, $now) : (undef, 'no mailFrom');
      if ($why || !ref $from || !defined $from->{email}
          || grep { ref $_ ne 'HASH' || !defined $_->{email} || defined $_->{parameters} } @rcpt) {
        $notcreated{$cid} = { type => 'invalidProperties', properties => ['envelope'],
                              ($why ? (description => $why) : ()) };
        next;
      }
      $release = $when;
    }
    $ready{$cid} = [$msgid, $thrid, $envelope, $release];
  }
  $Self->commit();

  my %message;
  foreach my $cid (sort keys %ready) {
    my ($msgid, $thrid, $envelope, $release) = @{$ready{$cid}};
    my ($type, $rfc822) = $Self->get_raw_message($msgid);
    # RFC 8621 S7: a null envelope is generated from the Email: mailFrom from
    # Sender, else From; rcptTo the deduplicated To, Cc and Bcc addresses.
    $envelope //= _generate_envelope($rfc822);
    $ready{$cid}[2] = $envelope;
    my @rcpt = map { $_->{email} } @{$envelope->{rcptTo} || []};
    unless (@rcpt) {
      $notcreated{$cid} = { type => 'noRecipients' };
      next;
    }
    if (my @bad = grep { !/^[^\s@]+@[^\s@]+$/ } @rcpt) {
      $notcreated{$cid} = { type => 'invalidRecipients', invalidRecipients => \@bad };
      next;
    }
    # what is sent is the message as it is now, whatever happens to the Email
    $message{$cid} = _strip_bcc($rfc822);
  }

  foreach my $cid (sort keys %message) {
    my ($msgid, $thrid, $envelope, $release) = @{$ready{$cid}};
    my $held = defined $release && $release > $now;
    my $sendat = $held ? $release : $now;

    unless ($held) {
      eval { $Self->backend_cmd('send_email', $message{$cid}, _smtp_envelope($envelope)) };
      if ($@) {
        (my $err = "$@") =~ s/\s+at \S+ line \d+.*//s;
        warn "send_email failed for $cid: $err\n";
        $notcreated{$cid} = { type => 'serverFail', description => $err };
        next;
      }
    }

    $Self->begin();
    my $id = $Self->dmake('jsubmission', {
      sendat     => $sendat,
      msgid      => $msgid,
      thrid      => $thrid,
      envelope   => $json->encode($envelope),
      identity   => $new->{$cid}{identityId},
      undoStatus => $held ? 'pending' : 'final',
    });
    $Self->commit();
    $Self->write_subdir('outbox', "$id.eml", $message{$cid}) if $held;
    $Self->{_sendat_changed} = 1 if $held;

    # RFC 8620 S5.3: created carries the server-set properties
    $createmap{$cid} = {
      id         => "$id",
      sendAt     => Data::JSEmail::isodate($sendat),
      undoStatus => $held ? 'pending' : 'final',
      (defined $new->{$cid}{envelope} ? () : (envelope => $envelope)),
    };
  }

  return (\%createmap, \%notcreated);
}

sub update_submissions {
  my $Self = shift;
  my $changed = shift;
  my $idmap = shift;

  my (%updated, %notupdated);
  for my $id (sort keys %$changed) {
    my $patch = $changed->{$id};
    my $subid = $idmap->($id);
    $Self->begin();
    my $row = $Self->dgetone('jsubmission', { jsubid => $subid, active => 1 });
    $Self->commit();
    unless ($row) {
      $notupdated{$id} = { type => 'notFound' };
      next;
    }
    # RFC 8621 S7: undoStatus may be set to "canceled"; nothing else changes
    my $status = $row->{undoStatus} // $row->{undostatus} // 'final';
    if (my @bad = grep { $_ ne 'undoStatus' || ($patch->{$_} // '') !~ /^(?:canceled|\Q$status\E)$/ } keys %$patch) {
      $notupdated{$id} = { type => 'invalidProperties', properties => \@bad };
      next;
    }
    if (exists $patch->{undoStatus} && $patch->{undoStatus} ne $status) {
      unless ($status eq 'pending') {
        $notupdated{$id} = { type => 'cannotUnsend' };
        next;
      }
      $Self->begin();
      $Self->ddirty('jsubmission', { undoStatus => 'canceled' }, { jsubid => $subid });
      $Self->commit();
      $Self->unlink_subdir('outbox', "$subid.eml");
      $Self->{_sendat_changed} = 1;
    }
    # keyed by the real id, even when the client named it "#creationId"
    $updated{$subid} = undef;
  }
  return (\%updated, \%notupdated);
}

sub destroy_submissions {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my @destroyed;
  my %notdestroyed;
  foreach my $subid (@$destroy) {
    my $active = $Self->dgetfield('jsubmission', { jsubid => $subid }, 'active');
    if ($active) {
      push @destroyed, $subid;
      # RFC 8621 S7.5: destroying "MUST NOT affect the deliveries it
      # represents" -- a held message still goes out; this only removes the
      # record, and keeps the row so /changes can report it destroyed.
      $Self->ddirty('jsubmission', { active => 0 }, { jsubid => $subid });
    }
    else {
      $notdestroyed{$subid} = {type => 'notFound', description => "submission not found"};
    }
  }

  $Self->commit();

  return (\@destroyed, \%notdestroyed);
}

# The time the next held submission is due, or undef if none is pending.
sub next_send_due {
  my $Self = shift;
  $Self->begin();
  my ($when) = $Self->dbh->selectrow_array(
    "SELECT MIN(sendat) FROM jsubmission WHERE undoStatus = 'pending'");
  $Self->commit();
  return $when;
}

# Send every held submission whose time has come; returns next_send_due.
sub send_due {
  my $Self = shift;
  my $now = time();
  $Self->begin();
  my $due = $Self->dbh->selectall_arrayref(
    "SELECT jsubid, envelope FROM jsubmission WHERE undoStatus = 'pending' AND sendat <= ?",
    { Slice => {} }, $now);
  $Self->commit();

  for my $row (@$due) {
    my $id = $row->{jsubid};
    my $message = $Self->read_subdir('outbox', "$id.eml");
    if (defined $message) {
      eval { $Self->backend_cmd('send_email', $message, _smtp_envelope(decode_json($row->{envelope}))) };
      if ($@) {
        # leave it pending: the next send_due tries again
        warn "send_due: submission $id failed, will retry: $@";
        next;
      }
    }
    else {
      warn "send_due: submission $id has no held message\n";
    }
    $Self->begin();
    $Self->ddirty('jsubmission', { undoStatus => 'final' }, { jsubid => $id });
    $Self->commit();
    $Self->unlink_subdir('outbox', "$id.eml");
  }

  return $Self->next_send_due();
}

sub _create_user_tables {
  my ($Self, $dbh) = @_;

  $Self->SUPER::_create_user_tables($dbh);

  # XXX - password encryption?
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iserver (
  username TEXT PRIMARY KEY,
  password TEXT,
  imapHost TEXT,
  imapPort INTEGER,
  imapSSL INTEGER,
  imapPrefix TEXT,
  imapSep TEXT,
  smtpHost TEXT,
  smtpPort INTEGER,
  smtpSSL INTEGER,
  caldavURL TEXT,
  carddavURL TEXT,
  webdavURL TEXT,
  webdavFeatures TEXT,
  lastfilesync INTEGER,
  lastfoldersync DATE,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ifolders (
  ifolderid INTEGER PRIMARY KEY NOT NULL,
  jmailboxid INTEGER,
  sep TEXT NOT NULL,
  imapname TEXT NOT NULL,
  label TEXT,
  uidvalidity INTEGER,
  uidfirst INTEGER,
  uidnext INTEGER,
  highestmodseq INTEGER,
  uniqueid TEXT,
  myrights TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ifolderj ON ifolders (jmailboxid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS ifolderlabel ON ifolders (label)");


  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS imessages (
  imessageid INTEGER PRIMARY KEY NOT NULL,
  ifolderid INTEGER,
  uid INTEGER,
  internaldate DATE,
  modseq INTEGER,
  flags TEXT,
  labels TEXT,
  thrid TEXT,
  msgid TEXT,
  envelope TEXT,
  bodystructure TEXT,
  size INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE UNIQUE INDEX IF NOT EXISTS imsgfrom ON imessages (ifolderid, uid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS imessageid ON imessages (msgid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS imessagethrid ON imessages (thrid)");

# not used for Gmail, but it doesn't hurt to have it
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ithread (
  messageid TEXT PRIMARY KEY,
  sortsubject TEXT,
  thrid TEXT
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ithrid ON ithread (thrid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icalendars (
  icalendarid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  sortOrder INTEGER,
  color TEXT,
  syncToken TEXT,
  jcalendarid INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ievents (
  ieventid INTEGER PRIMARY KEY NOT NULL,
  icalendarid INTEGER,
  href TEXT,
  etag TEXT,
  uid TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ieventcal ON ievents (icalendarid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS ieventuid ON ievents (uid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iaddressbooks (
  iaddressbookid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  sortOrder INTEGER,
  syncToken TEXT,
  jaddressbookid INTEGER,
  mtime DATE NOT NULL
);
EOF

# XXX - should we store 'kind' in this?  Means we know which j table to update
# if someone reuses a UID from a contact to a group or vice versa...
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icards (
  icardid INTEGER PRIMARY KEY NOT NULL,
  iaddressbookid INTEGER,
  href TEXT,
  etag TEXT,
  uid TEXT,
  kind TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS icardbook ON icards (iaddressbookid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS icarduid ON icards (uid)");

  $dbh->do("CREATE TABLE IF NOT EXISTS imsgidtodo (msgid TEXT PRIMARY KEY NOT NULL)");

}

1;
