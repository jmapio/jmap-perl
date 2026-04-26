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

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

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

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateThread}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;

  my $data = $Self->{db}->dget('jthreads', { jmodseq => ['>', $args->{sinceState}] }, 'thrid,active,jcreated,jmodseq');

  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless defined $data;

  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'thrid');

  my @res;
  push @res, ['Thread/changes', {
    accountId => $accountid,
    oldState => $args->{sinceState},
    newState => $newState,
    created => $created,
    updated => $updated,
    destroyed => $destroyed,
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
