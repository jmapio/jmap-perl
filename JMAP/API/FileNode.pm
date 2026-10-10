package JMAP::API;
use strict;
use warnings;

# FileNode (draft-ietf-jmap-filenode) over the jfilenodes mirror that
# JMAP::ImapDB::sync_files keeps of the account's WebDAV tree.

use JSON;
use JMAP::FileNode;

my @FILENODE_PROPERTIES = qw(
  id parentId nodeType blobId target size name type created modified
  accessed changed executable isSubscribed myRights shareWith role
);

# draft S3.1: one mirror row as a FileNode object.  $byid maps nodeid to row,
# for the parent's privileges (mayRename and mayDelete are rights over the
# parent: WebDAV's unbind).
sub _filenode_object {
  my ($Self, $row, $byid) = @_;
  my $parent = defined $row->{parentid} ? $byid->{$row->{parentid}} : undef;
  my $privs  = defined $row->{privs} ? [ split ' ', $row->{privs} ] : undef;
  my $pprivs = $parent && defined $parent->{privs} ? [ split ' ', $parent->{privs} ] : undef;
  my $isfile = $row->{nodetype} eq 'file';
  my $rights = JMAP::FileNode::rights($privs, $pprivs);
  # the home collection is the account's single top-level node: it cannot
  # be renamed, moved or destroyed (mayCreateTopLevelFileNode is false)
  @$rights{qw(mayRename mayDelete)} = (JSON::false, JSON::false) unless defined $row->{parentid};
  return {
    id           => "$row->{nodeid}",
    parentId     => (defined $row->{parentid} ? "$row->{parentid}" : undef),
    nodeType     => $row->{nodetype},
    blobId       => $isfile ? JMAP::FileNode::blob_id($row->{nodeid}, $row->{etag}) : undef,
    target       => undef,
    size         => $isfile ? 0 + ($row->{size} // 0) : undef,
    name         => $row->{name},
    type         => $isfile ? $row->{type} : undef,
    created      => JMAP::FileNode::utc($row->{created} // $row->{modified} // $row->{changed}),
    modified     => JMAP::FileNode::utc($row->{modified} // $row->{changed}),
    accessed     => JMAP::FileNode::utc($row->{accessed} // $row->{modified} // $row->{changed}),
    changed      => JMAP::FileNode::utc($row->{changed}),
    executable   => $row->{executable} ? JSON::true : JSON::false,
    isSubscribed => (($row->{isSubscribed} // 1) ? JSON::true : JSON::false),
    myRights     => $rights,
    shareWith    => undef,
    role         => $row->{role},
  };
}

# Sync first when the mirror is stale (spec "Sync": 60s on demand).  The sync
# talks to WebDAV, so it MUST run before _api_init opens the transaction.
sub _filenode_init {
  my ($Self, $args, $maxage) = @_;
  $Self->{db}->sync_files_if_due($maxage // 60)
    if $Self->{db}->can('sync_files_if_due')
       && !($args->{accountId} && $args->{accountId} ne $Self->{db}->accountid());
  return $Self->_api_init($args);
}

sub api_FileNode_get {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  if ($args->{properties}) {
    my %known = map { $_ => 1 } @FILENODE_PROPERTIES;
    my @bad = grep { !$known{$_} } @{$args->{properties}};
    return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['properties'],
                                         description => "unknown properties: @bad"}]) if @bad;
  }

  my $rows = $Self->{db}->filenode_rows();
  my %byid = map { $_->{nodeid} => $_ } @$rows;

  my @want = defined $args->{ids} ? (map { $Self->idmap($_) // $_ } @{$args->{ids}})
                                  : (map { $_->{nodeid} } @$rows);
  my (%seen, @list, @notfound);
  for my $id (@want) {
    next if $seen{$id}++;
    my $row = $byid{$id} or do { push @notfound, $id; next };
    push @list, $row;
  }
  # draft S3.2.1 fetchParents: every ancestor, once
  if ($args->{fetchParents}) {
    for my $row (@list) {
      my $p = $row->{parentid};
      while (defined $p && !$seen{$p}++) {
        my $prow = $byid{$p} or last;
        push @list, $prow;   # appended: this loop visits it too, harmlessly
        $p = $prow->{parentid};
      }
    }
  }
  # the state read in the same transaction as the rows, so it matches them
  my $state = "$user->{jstateFileNode}";
  $Self->commit();

  my @objs = map { $Self->_filenode_object($_, \%byid) } @list;
  if ($args->{properties}) {
    my %want = map { $_ => 1 } 'id', @{$args->{properties}};
    @objs = map { my $o = $_; +{ map { ($_ => $o->{$_}) } grep { $want{$_} } keys %$o } } @objs;
  }
  return ['FileNode/get', { accountId => "$accountid", state => $state,
                            list => \@objs, notFound => [ map { "$_" } @notfound ] }];
}

sub api_FileNode_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateFileNode}";
  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $sinceState = $args->{sinceState};

  my $data = $Self->{db}->dget('jfilenodes', { jmodseq => ['>', $sinceState] },
                               'nodeid,active,jcreated,jmodseq');
  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    unless defined $data;
  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $sinceState, 'nodeid');
  return ['FileNode/changes', {
    accountId      => "$accountid",
    oldState       => "$sinceState",
    newState       => $newState,
    hasMoreChanges => ($partial ? JSON::true : JSON::false),
    created        => $created,
    updated        => $updated,
    destroyed      => $destroyed,
  }];
}

1;
