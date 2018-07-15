#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::DB;

use Data::Dumper;
use DBI;
use DBI qw(:sql_types);
use Carp qw(confess);

use Data::UUID::LibUUID;
use IO::LockedFile;
use JSON::XS qw(decode_json);
use Email::MIME;
# seriously, it's parsable, get over it
$Email::MIME::ContentType::STRICT_PARAMS = 0;
use HTML::Strip;
use Image::Size;
use Email::Address::XS qw(parse_email_groups);
use Email::MIME::Header::AddressList;
use Encode;
use Encode::MIME::Header;
use DateTime;
use Date::Parse;
use Net::CalDAVTalk;
use Net::CardDAVTalk::VCard;
use MIME::Base64 qw(encode_base64 decode_base64);
use Scalar::Util qw(weaken);
use JMAP::EmailObject;

my $json = JSON::XS->new->utf8->canonical();

my %TABLE2GROUPS = (
  jmessages => ['Email'],
  jthreads => ['Thread'],
  jmailboxes => ['Mailbox'],
  jmessagemap => ['Mailbox'],
  jrawmessage => [],
  jfiles => [], # for now
  jcalendars => ['Calendar'],
  jevents => ['CalendarEvent'],
  jaddressbooks => [], # not directly
  jcontactgroups => ['ContactGroup'],
  jcontactgroupmap => ['ContactGroup'],
  jcontacts => ['Contact'],
  jclientprefs => ['ClientPreferences'],
  jcalendarprefs => ['CalendarPreferences'],
);

sub new {
  my $class = shift;
  my $accountid = shift || die;
  my $Self = bless { accountid => $accountid, start => time() }, ref($class) || $class;
  my $dbh = DBI->connect("dbi:SQLite:dbname=/home/jmap/data/$accountid.sqlite3");
  $Self->_initdb($dbh);
  return $Self;
}

sub delete {
  my $Self = shift;
  my $accountid = $Self->accountid();
  delete $Self->{dbh};
  unlink("/home/jmap/data/$accountid.sqlite3");
}

sub accountid {
  my $Self = shift;
  return $Self->{accountid};
}

sub log {
  my $Self = shift;
  if ($Self->{logger}) {
    $Self->{logger}->(@_);
  }
  else {
    my ($level, @items) = @_;
    return if (not $ENV{DEBUGDB} and $level eq 'debug');
    my $time = time() - $Self->{start};
    warn "[$$ $level $time]: @items\n";
  }
}

sub dbh {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  return $Self->{t}{dbh};
}

sub in_transaction {
  my $Self = shift;
  return $Self->{t} ? 1 : 0;
}

sub begin_superlock {
  my $Self = shift;
  my $accountid = $Self->accountid();
  my $lock = IO::LockedFile->new(">/home/jmap/data/$accountid.lock");
  $Self->{superlock} = $lock;
  weaken $Self->{superlock};
  return $lock;
}

sub begin {
  my $Self = shift;
  confess("ALREADY IN TRANSACTION") if $Self->{t};
  my $accountid = $Self->accountid();
  # we need this because sqlite locking isn't as robust as you might hope
  $Self->{t} = {lock => $Self->{superlock} || IO::LockedFile->new(">/home/jmap/data/$accountid.lock")};
  $Self->{t}{dbh} = DBI->connect("dbi:SQLite:dbname=/home/jmap/data/$accountid.sqlite3");
  $Self->{t}{dbh}->begin_work();
}

sub commit {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};

  # push an update if anything to tell..
  my $t = $Self->{t};

  my $mbupdates = delete $t->{update_mailbox_counts};
  if ($mbupdates) {
    foreach my $jmailboxid (keys %$mbupdates) {
      my %update;
      # re-calculate all the counts.  In theory we could do something clever with delta updates, but this will work
      ($update{totalEmails}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $jmailboxid);
      ($update{unreadEmails}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT msgid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.isUnread = 1 AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $jmailboxid);
      ($update{totalThreads}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT thrid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1", {}, $jmailboxid);
      ($update{unreadThreads}) = $Self->dbh->selectrow_array("SELECT COUNT(DISTINCT thrid) FROM jmessages JOIN jmessagemap USING (msgid) WHERE jmailboxid = ? AND jmessages.active = 1 AND jmessagemap.active = 1 AND thrid IN (SELECT thrid FROM jmessages JOIN jmessagemap USING (msgid) WHERE isUnread = 1 AND jmessages.active = 1 AND jmessagemap.active = 1)", {}, $jmailboxid);

      $update{$_} += 0 for keys %update;  # make sure they're numeric

      $Self->dmaybedirty('jmailboxes', \%update, {jmailboxid => $jmailboxid});
    }
  }
  if ($t->{modseq} and $Self->{change_cb}) {
    my %map;
    my %dbdata = (jhighestmodseq => $t->{modseq});
    my $state = "$t->{modseq}";
    foreach my $table (keys %{$t->{tables}}) {
      foreach my $group (@{$TABLE2GROUPS{$table}}) {
        $map{$group} = $state;
        $dbdata{"jstate$group"} = $state;
      }
    }

    $Self->dupdate('account', \%dbdata);
    $Self->{change_cb}->($Self, \%map, $state) unless $Self->{t}->{backfilling};
  }

  $Self->{t}{dbh}->commit();
  delete $Self->{t};
}

sub rollback {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  $Self->{t}{dbh}->rollback();
  delete $Self->{t};
}

# handy for error cases
sub reset {
  my $Self = shift;
  return unless $Self->{t};
  $Self->{t}{dbh}->rollback();
  delete $Self->{t};
}

sub dirty {
  my $Self = shift;
  my $table = shift || die 'need to have a table to dirty';
  unless ($Self->{t}{modseq}) {
    my $user = $Self->get_user();
    $user->{jhighestmodseq}++;
    $Self->{t}{modseq} = $user->{jhighestmodseq};
    $Self->log('debug', "dirty at $user->{jhighestmodseq}");
  }
  $Self->{t}{tables}{$table} = $Self->{t}{modseq};
  return $Self->{t}{modseq};
}

sub get_user {
  my $Self = shift;
  unless ($Self->{t}{user}) {
    $Self->{t}{user} = $Self->dgetone('account');
  }
  # bootstrap
  unless ($Self->{t}{user}) {
    my $data = {
      jhighestmodseq => 1,
    };
    $Self->dinsert('account', $data);
    $Self->{t}{user} = $data;
  }
  return $Self->{t}{user};
}

sub touch_thread_by_msgid {
  my $Self = shift;
  my $msgid = shift;

  my $thrid = $Self->dgetfield('jmessages', { msgid => $msgid }, 'thrid');
  return unless $thrid;

  my $data = $Self->dget('jmessages', { thrid => $thrid, active => 1 });
  unless (@$data) {
    $Self->dmaybedirty('jthreads', {active => 0, data => '[]'}, {thrid => $thrid});
    return;
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

  # have to handle doesn't exist case dammit, dmaybdirty isn't good for that
  my $exists = $Self->dgetfield('jthreads', { thrid => $thrid }, 'jcreated');
  if ($exists) {
    $Self->dmaybedirty('jthreads', {active => 1, data => $json->encode(\@msgs)}, {thrid => $thrid});
  }
  else {
    $Self->dmake('jthreads', {thrid => $thrid, data => $json->encode(\@msgs)});
  }
}

sub add_message {
  my $Self = shift;
  my ($data, $mailboxes) = @_;

  return unless @$mailboxes; # no mailboxes, no message

  $Self->dmake('jmessages', {%$data, keywords => $json->encode($data->{keywords})});
  foreach my $mailbox (@$mailboxes) {
    $Self->add_message_to_mailbox($data->{msgid}, $mailbox);
  }
  $Self->touch_thread_by_msgid($data->{msgid});
}

sub update_prefs {
  my $Self = shift;
  my $type = shift;
  my $data = shift;

  my %map = (
    UserPreferences => 'juserprefs',
    ClientPreferences => 'jclientprefs',
    CalendarPreferences => 'jcalendarprefs',
  );

  $Self->begin();
  $Self->dmake($map{$type}, { jprefid => $data->{id}, payload => $json->encode($data) });
  $Self->commit();

  return {};
}

sub update_mailbox_counts {
  my $Self = shift;
  my ($jmailboxid, $jmodseq) = @_;

  die "NOT IN TRANSACTION" unless $Self->{t};
  $Self->{t}{update_mailbox_counts}{$jmailboxid} = $jmodseq;
}

sub add_message_to_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {msgid => $msgid, jmailboxid => $jmailboxid};
  $Self->dmake('jmessagemap', $data);
  $Self->update_mailbox_counts($jmailboxid, $data->{jmodseq});
  $Self->ddirty('jmessages', {}, {msgid => $msgid});
}

sub delete_message_from_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {active => 0};
  $Self->dmaybedirty('jmessagemap', $data, {msgid => $msgid, jmailboxid => $jmailboxid});
  $Self->update_mailbox_counts($jmailboxid, $data->{jmodseq});
  $Self->ddirty('jmessages', {}, {msgid => $msgid});
}

sub change_message {
  my $Self = shift;
  my ($msgid, $data, $newids) = @_;

  my $keywords = $data->{keywords} || {};
  my $bump = $Self->dmaybedirty('jmessages', {
    keywords => $json->encode($keywords),
    isDraft => $keywords->{'$draft'} ? 1 : 0,
    isUnread => $keywords->{'$seen'} ? 0 : 1,
  }, {msgid => $msgid});

  my $oldids = $Self->dgetcol('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid');
  my %old = map { $_ => 1 } @$oldids;

  foreach my $jmailboxid (@$newids) {
    if (delete $old{$jmailboxid}) {
      # just bump the modseq
      $Self->update_mailbox_counts($jmailboxid, $data->{jmodseq}) if $bump;
    }
    else {
      $Self->add_message_to_mailbox($msgid, $jmailboxid);
    }
  }

  foreach my $jmailboxid (keys %old) {
    $Self->delete_message_from_mailbox($msgid, $jmailboxid);
  }
  $Self->touch_thread_by_msgid($msgid);
}

sub get_blob {
  my $Self = shift;
  my $blobId = shift;

  return () unless $blobId =~ m/^([mf])-([^-]+)(?:-(.*))?/;
  my $source = $1;
  my $id = $2;
  my $part = $3;

  if ($source eq 'f') {
    return $Self->get_file($id);
  }
  if ($source eq 'm') {
    return $Self->get_raw_message($id, $part);
  }
}

# NOTE: this can ONLY be used to create draft messages
sub create_messages {
  my $Self = shift;
  my $args = shift;
  my $idmap = shift;
  my %created;
  my %notCreated;

  return ({}, {}) unless %$args;

  $Self->begin();

  # XXX - get draft mailbox ID
  my $draftid = $Self->dgetfield('jmailboxes', { role => 'drafts' }, 'jmailboxid');

  $Self->commit();

  my %todo;
  foreach my $cid (keys %$args) {
    my $item = $args->{$cid};
    my $mailboxIds = delete $item->{mailboxIds};
    my $keywords = delete $item->{keywords};
    $item->{msgdate} = time();
    $item->{headers}{'Message-ID'} ||= "<" . new_uuid_string() . ".$item->{msgdate}\@$ENV{jmaphost}>";
    my $message = JMAP::EmailObject::make($item, sub { $Self->get_blob(@_) } );
    # XXX - let's just assume goodness for now - lots of error handling to add
    $todo{$cid} = [$message, $mailboxIds, $keywords];
  }

  foreach my $cid (keys %todo) {
    my ($message, $mailboxIds, $keywords) = @{$todo{$cid}};
    my @mailboxes = map { $idmap->($_) } keys %$mailboxIds;
    my ($msgid, $thrid) = $Self->import_message($message, \@mailboxes, $keywords);
    $created{$cid} = {
      id => $msgid,
      threadId => $thrid,
      size => length($message),
      # XXX: other fields to reply
    };
  }

  return (\%created, \%notCreated);
}

sub update_messages {
  my $Self = shift;
  die "Virtual method";
}

sub destroy_messages {
  my $Self = shift;
  die "Virtual method";
}

sub delete_message {
  my $Self = shift;
  my ($msgid) = @_;

  $Self->dmaybedirty('jmessages', {active => 0}, {msgid => $msgid});
  my $oldids = $Self->dgetcol('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid');
  $Self->delete_message_from_mailbox($msgid, $_) for @$oldids;
  $Self->touch_thread_by_msgid($msgid);
}

# returns reported and notFound as a tuple
sub report_messages {
  my $Self = shift;
  my $msgids = shift;
  my $asSpam = shift;

  # XXX - actually report the messages (or at least check that they exist)

  return ($msgids, []);
}

sub parse_event {
  my $Self = shift;
  my $raw = shift;
  my $CalDAV = Net::CalDAVTalk->new(url => 'http://localhost/');  # empty caldav
  my ($event) = $CalDAV->vcalendarToEvents($raw);
  return $event;
}

sub set_event {
  my $Self = shift;
  my $jcalendarid = shift;
  my $event = shift;
  my $eventuid = delete $event->{uid};
  $Self->dmake('jevents', {
    eventuid => $eventuid,
    jcalendarid => $jcalendarid,
    payload => $json->encode($event),
  });
}

sub delete_event {
  my $Self = shift;
  my $jcalendarid = shift; # doesn't matter
  my $eventuid = shift;
  return $Self->dmaybedirty('jevents', {active => 0}, {eventuid => $eventuid});
}

sub parse_card {
  my $Self = shift;
  my $raw = shift;
  my ($card) = Net::CardDAVTalk::VCard->new_fromstring($raw);

  my %hash;

  $hash{uid} = $card->uid();
  $hash{kind} = $card->VKind();

  if ($hash{kind} eq 'contact') {
    $hash{lastName} = $card->VLastName();
    $hash{firstName} = $card->VFirstName();
    $hash{prefix} = $card->VTitle();

    $hash{company} = $card->VCompany();
    $hash{department} = $card->VDepartment();

    $hash{emails} = [$card->VEmails()];
    $hash{addresses} = [$card->VAddresses()];
    $hash{phones} = [$card->VPhones()];
    $hash{online} = [$card->VOnline()];

    $hash{nickname} = $card->VNickname();
    $hash{birthday} = $card->VBirthday();
    $hash{notes} = $card->VNotes();
  }
  else {
    $hash{name} = $card->VFN();
    $hash{members} = [$card->VGroupContactUIDs()];
  }

  return \%hash;
}

sub set_card {
  my $Self = shift;
  my $jaddressbookid = shift;
  my $card = shift;
  my $carduid = delete $card->{uid};
  my $kind = delete $card->{kind};
  if ($kind eq 'contact') {
    $Self->dmake('jcontacts', {
      contactuid => $carduid,
      jaddressbookid => $jaddressbookid,
      payload => $json->encode($card),
    });
  }
  else {
    $Self->dmake('jcontactgroups', {
      groupuid => $carduid,
      jaddressbookid => $jaddressbookid,
      name => $card->{name},
    });
    $Self->ddelete('jcontactgroupmap', {groupuid => $carduid});
    foreach my $item (@{$card->{members}}) {
      $Self->dinsert('jcontactgroupmap', {
        groupuid => $carduid,
        contactuid => $item,
      });
    }
  }
}

sub delete_card {
  my $Self = shift;
  my $jaddressbookid = shift; # doesn't matter
  my $carduid = shift;
  my $kind = shift;
  if ($kind eq 'contact') {
    $Self->dmaybedirty('jcontacts', {active => 0}, {contactuid => $carduid, jaddressbookid => $jaddressbookid});
  }
  else {
    $Self->dmaybedirty('jcontactgroups', {active => 0}, {groupuid => $carduid, jaddressbookid => $jaddressbookid});
  }
}

sub put_file {
  my $Self = shift;
  my $accountid = shift;
  my $type = shift;
  my $content = shift;
  my $expires = shift // time() + (7 * 86400);

  my $size = length($content);

  $Self->begin();

  my $statement = $Self->dbh->prepare('INSERT OR REPLACE INTO jfiles (type, size, content, expires) VALUES (?, ?, ?, ?)');

  $statement->bind_param(1, $type);
  $statement->bind_param(2, $size);
  $statement->bind_param(3, $content, SQL_BLOB);
  $statement->bind_param(4, $expires);
  $statement->execute();

  my $id = $Self->dbh->last_insert_id(undef, undef, undef, undef);

  $Self->commit();

  return {
    accountId => "$accountid",
    blobId => "f-$id",
    type => $type,
    expires => JMAP::EmailObject::isodate($expires),
    size => $size,
    url => "https://$ENV{jmaphost}/raw/$accountid/f-$id"
  };
}

sub get_file {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->dgetone('jfiles', { jfileid => $id }, 'type,content');
  $Self->commit();

  return unless $data;
  return ($data->{type}, $data->{content});
}

sub _dbl {
  return '(' . join(', ', map { defined $_ ? "'$_'" : 'NULL' } @_) . ')';
}

sub dinsert {
  my $Self = shift;
  my ($table, $values) = @_;

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my $sql = "INSERT OR REPLACE INTO $table (" . join(', ', @keys) . ") VALUES (" . join (', ', map { "?" } @keys) . ")";

  $Self->log('debug', $sql, _dbl( map { $values->{$_} } @keys));

  $Self->dbh->do($sql, {}, map { $values->{$_} } @keys);

  my $id = $Self->dbh->last_insert_id(undef, undef, undef, undef);
  return $id;
}

# dinsert with a modseq
sub dmake {
  my $Self = shift;
  my ($table, $values, @modseqfields) = @_;
  my $modseq = $Self->dirty($table);
  foreach my $field ('jcreated', 'jmodseq', @modseqfields) {
    $values->{$field} = $modseq;
  }
  $values->{active} = 1;
  return $Self->dinsert($table, $values);
}

sub dupdate {
  my $Self = shift;
  my ($table, $values, $filter) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my @lkeys = $filter ? sort keys %$filter : ();

  my $sql = "UPDATE $table SET " . join (', ', map { "$_ = ?" } @keys);
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl(map { $values->{$_} } @keys), _dbl(map { $filter->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, (map { $values->{$_} } @keys), (map { $filter->{$_} } @lkeys));
}

sub filter_values {
  my $Self = shift;
  my ($table, $values, $filter) = @_;

  # copy so we don't edit the originals
  my %values = $values ? %$values : ();

  my @keys = sort keys %values;
  my @lkeys = $filter ? sort keys %$filter : ();

  my $sql = "SELECT " . join(', ', @keys) . " FROM $table";
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;
  $Self->log('debug', $sql, _dbl(map { $filter->{$_} } @lkeys));
  my $data = $Self->dbh->selectrow_hashref($sql, {}, map { $filter->{$_} } @lkeys);
  foreach my $key (@keys) {
    delete $values{$key} if $filter->{$key}; # in the filter, no point setting again
    delete $values{$key} if ($data->{$key} || '') eq ($values{$key} || '');
  }

  return \%values;
}

sub dmaybeupdate {
  my $Self = shift;
  my ($table, $values, $filter) = @_;

  my $filtered = $Self->filter_values($table, $values, $filter);
  return unless %$filtered;

  return $Self->dupdate($table, $filtered, $filter);
}

# dupdate with a modseq
sub ddirty {
  my $Self = shift;
  my ($table, $values, $filter) = @_;
  $values->{jmodseq} = $Self->dirty($table);
  return $Self->dupdate($table, $values, $filter);
}

sub dmaybedirty {
  my $Self = shift;
  my ($table, $values, $filter, @modseqfields) = @_;

  my $filtered = $Self->filter_values($table, $values, $filter);
  return unless %$filtered;

  my $modseq = $Self->dirty($table);
  foreach my $field ('jmodseq', @modseqfields) {
    $filtered->{$field} = $values->{$field} = $modseq;
  }

  return $Self->dupdate($table, $filtered, $filter);
}

sub dnuke {
  my $Self = shift;
  my ($table, $filter) = @_;

  my $modseq = $Self->dirty($table);

  my @lkeys = sort keys %$filter;
  my $sql = "UPDATE $table SET active = 0, jmodseq = ? WHERE active = 1";
  $sql .= " AND " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl($modseq), _dbl(map { $filter->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, $modseq, map { $filter->{$_} } @lkeys);
}

sub ddelete {
  my $Self = shift;
  my ($table, $filter) = @_;

  my @lkeys = sort keys %$filter;
  my $sql = "DELETE FROM $table";
  $sql .= " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys) if @lkeys;

  $Self->log('debug', $sql, _dbl(map { $filter->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, map { $filter->{$_} } @lkeys);
}

sub dget {
  my $Self = shift;
  my ($table, $filter, $fields) = @_;

  $fields ||= '*';

  my @lkeys = sort keys %$filter;
  my @lvals = map { $filter->{$_} } @lkeys;
  my $sql = "SELECT $fields FROM $table";
  $sql .= " WHERE " . join(' AND ', map { ref($filter->{$_}) eq 'ARRAY' ? "$_ $filter->{$_}[0] ?" : "$_ = ?" } @lkeys) if @lkeys;
  $sql .= " ORDER BY $fields" unless ($fields eq '*' or $fields eq 'COUNT(*)');
  my @vals = map { ref($_) eq 'ARRAY' ? $_->[1] : $_ } @lvals;

  $Self->log('debug', $sql, _dbl(@vals));

  return $Self->dbh->selectall_arrayref($sql, {Slice => {}}, @vals);
}

sub dcount {
  my $Self = shift;
  my ($table, $filter) = @_;

  my @lkeys = sort keys %$filter;
  my @lvals = map { $filter->{$_} } @lkeys;
  my $sql = "SELECT COUNT(*) FROM $table";
  $sql .= " WHERE " . join(' AND ', map { ref($filter->{$_}) eq 'ARRAY' ? "$_ $filter->{$_}[0] ?" : "$_ = ?" } @lkeys) if @lkeys;
  my @vals = map { ref($_) eq 'ARRAY' ? $_->[1] : $_ } @lvals;

  $Self->log('debug', $sql, _dbl(@vals));

  return ($Self->dbh->selectrow_array($sql, {}, @vals));
}

sub dgetby {
  my $Self = shift;
  my ($table, $hashkey, $filter, $fields) = @_;
  my $data = $Self->dget($table, $filter, $fields);
  return { map { $_->{$hashkey} => $_ } @$data };
}

sub dgetone {
  my $Self = shift;
  my ($table, $filter, $fields) = @_;

  $fields ||= '*';

  my @lkeys = sort keys %$filter;
  my @lvals = map { $filter->{$_} } @lkeys;
  my $sql = "SELECT $fields FROM $table";
  $sql .= " WHERE " . join(' AND ', map { ref($filter->{$_}) eq 'ARRAY' ? "$_ $filter->{$_}[0] ?" : "$_ = ?" } @lkeys) if @lkeys;
  $sql .= " LIMIT 1";
  my @vals = map { ref($_) eq 'ARRAY' ? $_->[1] : $_ } @lvals;

  $Self->log('debug', $sql, _dbl(map { $filter->{$_} } @lkeys));

  my $data = $Self->dbh->selectall_arrayref($sql, {Slice => {}}, @vals);
  return $data->[0];
}

sub dgetfield {
  my $Self = shift;
  my ($table, $filter, $field) = @_;
  my $res = $Self->dgetone($table, $filter, $field);
  return $res ? $res->{$field} : undef;
}

sub dgetcol {
  my $Self = shift;
  my ($table, $filter, $field) = @_;
  my $data = $Self->dget($table, $filter, $field);
  return [ map { $_->{$field} } @$data ];
}

sub _initdb {
  my $Self = shift;
  my $dbh = shift;

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessages (
  msgid TEXT PRIMARY KEY,
  thrid TEXT,
  internaldate INTEGER,
  sha1 TEXT,
  isDraft BOOL,
  isUnread BOOL,
  keywords TEXT,
  msgfrom TEXT,
  msgto TEXT,
  msgcc TEXT,
  msgbcc TEXT,
  msgsubject TEXT,
  msginreplyto TEXT,
  msgmessageid TEXT,
  msgdate INTEGER,
  msgsize INTEGER,
  sortsubject TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jthrid ON jmessages (thrid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS jmsgmessageid ON jmessages (msgmessageid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jthreads (
  thrid TEXT PRIMARY KEY,
  data TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmailboxes (
  jmailboxid TEXT NOT NULL PRIMARY KEY,
  parentId INTEGER,
  role TEXT,
  name TEXT,
  sortOrder INTEGER,
  isSubscribed INTEGER,
  mayReadItems BOOLEAN,
  mayAddItems BOOLEAN,
  mayRemoveItems BOOLEAN,
  maySetSeen BOOLEAN,
  maySetKeywords BOOLEAN,
  mayCreateChild BOOLEAN,
  mayRename BOOLEAN,
  mayDelete BOOLEAN,
  maySubmit BOOLEAN,
  totalEmails INTEGER,
  unreadEmails INTEGER,
  totalThreads INTEGER,
  unreadThreads INTEGER,
  jcreated INTEGER,
  jmodseq INTEGER,
  jnoncountsmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessagemap (
  jmailboxid TEXT,
  msgid TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN,
  PRIMARY KEY (jmailboxid, msgid)
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS msgidmap ON jmessagemap (msgid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS account (
  email TEXT,
  displayname TEXT,
  picture TEXT,
  jdeletedmodseq INTEGER NOT NULL DEFAULT 1,
  jhighestmodseq INTEGER NOT NULL DEFAULT 1,
  jstateMailbox TEXT NOT NULL DEFAULT 1,
  jstateThread TEXT NOT NULL DEFAULT 1,
  jstateEmail TEXT NOT NULL DEFAULT 1,
  jstateContact TEXT NOT NULL DEFAULT 1,
  jstateContactGroup TEXT NOT NULL DEFAULT 1,
  jstateCalendar TEXT NOT NULL DEFAULT 1,
  jstateCalendarEvent TEXT NOT NULL DEFAULT 1,
  jstateUserPreferences TEXT NOT NULL DEFAULT 1,
  jstateClientPreferences TEXT NOT NULL DEFAULT 1,
  jstateCalendarPreferences TEXT NOT NULL DEFAULT 1,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jrawmessage (
  msgid TEXT PRIMARY KEY,
  parsed TEXT,
  hasAttachment INTEGER,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfiles (
  jfileid INTEGER PRIMARY KEY,
  type TEXT,
  size INTEGER,
  content BLOB,
  expires DATE,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcalendars (
  jcalendarid INTEGER PRIMARY KEY,
  name TEXT,
  color TEXT,
  isVisible BOOLEAN,
  mayReadFreeBusy BOOLEAN,
  mayReadItems BOOLEAN,
  mayAddItems BOOLEAN,
  mayModifyItems BOOLEAN,
  mayRemoveItems BOOLEAN,
  mayDelete BOOLEAN,
  mayRename BOOLEAN,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jevents (
  eventuid TEXT PRIMARY KEY,
  jcalendarid INTEGER,
  firststart DATE,
  lastend DATE,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jeventcal ON jevents (jcalendarid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jaddressbooks (
  jaddressbookid INTEGER PRIMARY KEY,
  name TEXT,
  isVisible BOOLEAN,
  mayReadItems BOOLEAN,
  mayAddItems BOOLEAN,
  mayModifyItems BOOLEAN,
  mayRemoveItems BOOLEAN,
  mayDelete BOOLEAN,
  mayRename BOOLEAN,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcontactgroups (
  groupuid TEXT PRIMARY KEY,
  jaddressbookid INTEGER,
  name TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jgroupbook ON jcontactgroups (jaddressbookid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcontactgroupmap (
  groupuid TEXT,
  contactuid TEXT,
  mtime DATE,
  PRIMARY KEY (groupuid, contactuid)
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jcontactmap ON jcontactgroupmap (contactuid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcontacts (
  contactuid TEXT PRIMARY KEY,
  jaddressbookid INTEGER,
  isFlagged BOOLEAN,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jcontactbook ON jcontacts (jaddressbookid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jsubmission (
  jsubid INTEGER PRIMARY KEY,
  msgid TEXT,
  thrid TEXT,
  envelope TEXT,
  sendAt INTEGER,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS juserprefs (
  jprefid TEXT PRIMARY KEY,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jclientprefs (
  jprefid TEXT PRIMARY KEY,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jcalendarprefs (
  jprefid TEXT PRIMARY KEY,
  payload TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

}

1;
