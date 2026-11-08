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

  my @list;
  my %seenids;
  my %missingids;
  my @thrids;
  if (defined $args->{ids}) {
    @thrids = map { $Self->idmap($_) } @{$args->{ids}};
  }
  else {
    @thrids = map { $_->{thrid} } @{$Self->{db}->dget('jthreads', { active => 1 }, 'thrid')};
  }
  foreach my $thrid (@thrids) {
    next if $seenids{$thrid};
    $seenids{$thrid} = 1;
    my $data = $Self->{db}->dgetfield('jthreads', { thrid => $thrid, active => 1 }, 'data');
    unless ($data) {
      $missingids{$thrid} = 1;
      next;
    }
    my $jdata = $json->decode($data);
    # RFC 8621 S3: "sorted by the receivedAt date of the Email, oldest first",
    # ties broken stably (by id).
    my %date = map { $_->{msgid} => $_->{internaldate} // 0 }
               @{$Self->{db}->dget('jmessages', { thrid => $thrid, active => 1 }, 'msgid,internaldate')};
    my @ids = sort { ($date{$a} // 0) <=> ($date{$b} // 0) || $a cmp $b } @$jdata;
    push @list, {
      id => "$thrid",
      emailIds => [ map { "$_" } @ids ],
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
  my ($Self, $args) = @_;
  return $Self->_table_changes($args, method => 'Thread/changes',
    table => 'jthreads', key => 'thrid', state => 'jstateThread');
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
