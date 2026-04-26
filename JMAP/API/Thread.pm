package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Data::Dumper;

my $json = JSON::XS->new->utf8->canonical();

sub api_Thread_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateThread}";

  # XXX - error if no IDs

  my @list;
  my %seenids;
  my %missingids;
  foreach my $thrid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$thrid};
    $seenids{$thrid} = 1;
    my $data = $Self->{db}->dgetfield('jthreads', { thrid => $thrid, active => 1 }, 'data');
    unless ($data) {
      $missingids{$thrid} = 1;
      next;
    }
    my $jdata = $json->decode($data);
    push @list, {
      id => "$thrid",
      emailIds => [ map { "$_" } @$jdata ],
    };
  }

  $Self->commit();

  my @res;
  push @res, ['Thread/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];

  return @res;
}

sub api_Thread_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateThread}";

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceState']}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jthreads', { jmodseq => ['>', $args->{sinceState}] }, 'thrid,active,jcreated,jmodseq');

  my $partial = 0;
  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    $data = [ sort { $a->{jmodseq} <=> $b->{jmodseq} } @$data ];
    warn Dumper($data);
    my $next = $data->[$args->{maxChanges}];
    pop @$data while (@$data and $data->[-1]{jmodseq} == $next->{jmodseq});
    # couldn't find a set of changes that would work!
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless @$data;
    $newState = "$data->[-1]{jmodseq}";
    $partial = 1;
  }

  $Self->commit();

  my @created;
  my @updated;
  my @destroyed;
  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @updated, $row->{thrid};
      }
      else {
        push @created, $row->{thrid};
      }
    }
    else {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @destroyed, $row->{thrid};
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['Thread/changes', {
    accountId => $accountid,
    oldState => $args->{sinceState},
    newState => $newState,
    created => \@created,
    updated => \@updated,
    destroyed => \@destroyed,
    hasMoreChanges => $partial ? JSON::true : JSON::false,
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

1;
