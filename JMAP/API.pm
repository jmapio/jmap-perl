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
use Time::HiRes qw(gettimeofday tv_interval);
use Data::JSEmail;
use Date::Parse;
use B ();
use Email::Simple;
use Email::MIME;
use POSIX qw(strftime);

my $json = JSON::XS->new->utf8->canonical();

# Parameter type validation schemas for JMAP methods
# Types: string, uint (unsigned int), int, bool, [string] (array of strings),
#        {string} (hash with string keys), object, any
my %PARAM_SCHEMA = (
  'Email/get' => {
    accountId          => 'string?',
    ids                => '[string]',
    properties         => '[string]?',
    bodyProperties     => '[string]?',
    fetchTextBodyValues  => 'bool?',
    fetchHTMLBodyValues  => 'bool?',
    fetchAllBodyValues   => 'bool?',
    maxBodyValueBytes    => 'posint!',
  },
  'Email/query' => {
    accountId          => 'string?',
    filter             => 'object?',
    sort               => '[object]?',
    position           => 'int?',
    anchor             => 'string?',
    anchorOffset        => 'int?',
    limit              => 'uint?',
    collapseThreads    => 'bool?',
    calculateTotal     => 'bool?',
  },
  'Email/set' => {
    accountId          => 'string?',
    ifInState          => 'string?',
    create             => '{object}?',
    update             => '{object}?',
    destroy            => '[string]?',
  },
  'Email/import' => {
    accountId          => 'string?',
    ifInState          => 'string?',
    emails             => '{object}',
  },
  'Email/changes' => {
    accountId          => 'string?',
    sinceState         => 'string',
    maxChanges         => 'uint?',
  },
  'Mailbox/get' => {
    accountId          => 'string?',
    ids                => '[string]?',
    properties         => '[string]?',
  },
  'Mailbox/set' => {
    accountId          => 'string?',
    ifInState          => 'string?',
    create             => '{object}?',
    update             => '{object}?',
    destroy            => '[string]?',
    onDestroyRemoveMessages => 'bool?',
  },
  'Mailbox/query' => {
    accountId          => 'string?',
    filter             => 'object?',
    sort               => '[object]?',
    position           => 'int?',
    limit              => 'uint?',
    calculateTotal     => 'bool?',
  },
  'Mailbox/changes' => {
    accountId          => 'string?',
    sinceState         => 'string',
    maxChanges         => 'uint?',
  },
  'Thread/get' => {
    accountId          => 'string?',
    ids                => '[string]',
  },
  'Thread/changes' => {
    accountId          => 'string?',
    sinceState         => 'string',
    maxChanges         => 'uint?',
  },
);

# Validate a single value against a type spec
sub _validate_type {
  my ($value, $type) = @_;

  # ? = optional (key can be absent, null accepted)
  # ! = optional but not nullable (key can be absent, null rejected)
  my $optional = ($type =~ s/\?$//);
  my $notnull = ($type =~ s/!$//);
  return 1 if !defined $value && $optional;
  return 0 if !defined $value; # catches both required and !-marked

  # JSON::Typist wraps values in blessed objects — unwrap for type checking
  my $is_json_string = ref($value) && ref($value) =~ /String/;
  my $is_json_number = ref($value) && ref($value) =~ /Number/;

  if ($type eq 'string') {
    return 1 if $is_json_string;
    if (!ref($value)) {
      # Reject values that were JSON numbers (have IOK/NOK but not POK)
      my $flags = B::svref_2object(\$value)->FLAGS;
      my $is_num = $flags & (B::SVf_IOK | B::SVf_NOK);
      my $is_str = $flags & B::SVf_POK;
      return 0 if $is_num && !$is_str;
      return 1;
    }
    return 0;
  }
  elsif ($type eq 'uint' || $type eq 'posint' || $type eq 'int') {
    # Must be a JSON number, not a string that looks like a number
    if ($is_json_number) {
      my $v = 0 + "$value";
      return 0 if $type eq 'uint' && $v < 0;
      return 0 if $type eq 'posint' && $v < 1;
      return 0 if $type eq 'int' && "$value" !~ /^-?\d+$/;
      return 1;
    }
    if (!ref($value)) {
      # Plain scalar — check if it was decoded as a number (has IOK/NOK flag)
      my $flags = B::svref_2object(\$value)->FLAGS;
      my $is_num = $flags & (B::SVf_IOK | B::SVf_NOK);
      return 0 unless $is_num;
      return 0 if $type eq 'uint' && $value < 0;
      return 0 if $type eq 'posint' && $value < 1;
      return 1;
    }
    return 0;
  }
  elsif ($type eq 'bool') {
    # JSON booleans come through as various blessed refs
    return 1 if ref($value) && (
      ref($value) eq 'JSON::PP::Boolean' ||
      ref($value) eq 'JSON::XS::Boolean' ||
      ref($value) =~ /Boolean/
    );
    # Also accept scalar refs \0 and \1
    return 1 if ref($value) eq 'SCALAR';
    return 0;
  }
  elsif ($type eq '[string]') {
    return ref($value) eq 'ARRAY' && !grep { ref $_ } @$value;
  }
  elsif ($type eq '[object]') {
    return ref($value) eq 'ARRAY' && !grep { ref $_ ne 'HASH' } @$value;
  }
  elsif ($type eq '{object}') {
    return ref($value) eq 'HASH';
  }
  elsif ($type eq '{string}') {
    return ref($value) eq 'HASH' && !grep { ref $_ } values %$value;
  }
  elsif ($type eq 'object') {
    return ref($value) eq 'HASH';
  }
  elsif ($type eq 'any') {
    return 1;
  }
  return 0;
}

# Validate args against schema, return list of invalid argument names
sub _validate_args {
  my ($command, $args) = @_;
  my $schema = $PARAM_SCHEMA{$command};
  return () unless $schema; # no schema = no validation

  my @bad;
  for my $param (keys %$schema) {
    my $type = $schema->{$param};
    next if $type =~ /[\?!]$/ && !exists $args->{$param};
    if (exists $args->{$param}) {
      push @bad, $param unless _validate_type($args->{$param}, $type);
    }
    elsif ($type !~ /[\?!]$/) {
      # Required parameter missing
      push @bad, $param;
    }
  }
  return @bad;
}

sub new {
  my $class = shift;
  my $db = shift;

  return bless {db => $db}, ref($class) || $class;
}

sub api_Core_echo {
  my $Self = shift;
  my $args = shift;
  return ['Core/echo', $args];
}

# Convert empty containers to undef for JSON: {} → null, [] → null
# RFC 8620 /set responses use null (not empty) for absent result groups
sub _nullempty {
  my ($val) = @_;
  return undef unless defined $val;
  return undef if ref $val eq 'HASH' && !%$val;
  return undef if ref $val eq 'ARRAY' && !@$val;
  return $val;
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

  # Reset the creation-ID map for this request, then seed from any client-supplied
  # createdIds (RFC 8620 §3.4).  The client can pass previously-returned IDs to
  # chain across multiple /jmap calls.
  $Self->{idmap}      = {};
  $Self->{_seeded_ids} = {};
  if (ref $request->{createdIds} eq 'HASH') {
    my %seed = %{$request->{createdIds}};
    for my $id (keys %seed) {
      $Self->{idmap}{"#$id"}  = $seed{$id};
      $Self->{_seeded_ids}{$id} = 1;
    }
  }

  my $methods = $request->{methodCalls};

  foreach my $item (@$methods) {
    my $t0 = [gettimeofday];
    my ($command, $args, $tag) = @$item;
    my @items;
    my $can = $command;
    $can =~ s{/}{_};
    my $FuncRef = $Self->can("api_$can");
    my $logbit = '';
    if ($FuncRef) {
      my ($myargs, $error) = $Self->resolve_args($args);
      if ($myargs) {
        # Validate argument types
        my @bad = _validate_args($command, $myargs);
        if (@bad) {
          push @items, ['error', { type => 'invalidArguments', arguments => \@bad }];
          $Self->push_results($tag, @items);
          next;
        }
        if ($myargs->{ids}) {
          my @list = @{$myargs->{ids}};
          if (@list > 4) {
            my $len = @list;
            $#list = 3;
            $list[3] = '...' . $len;
          }
          $logbit .= " [" . join(",", @list) . "]";
        }
        if ($myargs->{properties}) {
          my @list = @{$myargs->{properties}};
          if (@list > 4) {
            my $len = @list;
            $#list = 3;
            $list[3] = '...' . $len;
          }
          $logbit .= " (" . join(",", @list) . ")";
        }

        @items = eval { $Self->$FuncRef($myargs, $tag) };
        if ($@) {
          warn "JMAP METHOD ERROR $command ($tag): $@\n";
          @items = ['error', { type => "serverError", message => "$@" }];
        }
        if ($Self->{db}->in_transaction()) {
          warn "JMAP STALE TRANSACTION after $command ($tag) - rolling back\n";
          $Self->{db}->reset();
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
    my $elapsed = tv_interval ($t0);
    warn "JMAP CMD $command$logbit took " . $elapsed . "\n";
  }

  # Build createdIds: only the IDs that were set during this request
  # (strip the leading '#' that we store internally).
  my %created_ids;
  for my $k (keys %{$Self->{idmap}}) {
    next unless $k =~ /^#(.+)$/;
    my $creation_id = $1;
    my $server_id   = $Self->{idmap}{$k};
    # Only include mappings that were set during this request, not seeded ones
    $created_ids{$creation_id} = $server_id
      if !exists $Self->{_seeded_ids}{$creation_id};
  }

  my $resp = { methodResponses => $Self->{results} };
  $resp->{createdIds} = \%created_ids if %created_ids;
  return $resp;
}


sub setid {
  my $Self = shift;
  my $key  = shift;
  my $val  = shift;
  $Self->{idmap}{"#$key"} = $val;
}

sub idmap {
  my $Self = shift;
  my $key = shift;
  return unless $key;
  my $val = exists $Self->{idmap}{$key} ? $Self->{idmap}{$key} : $key;
  return $val;
}

sub _api_init {
  my ($Self, $args) = @_;
  $Self->begin();
  my $user      = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return (undef, undef)
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  return ($user, $accountid);
}

sub _classify_changes {
  my ($Self, $data, $sinceState, $idField) = @_;
  my (@created, @updated, @destroyed);
  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $sinceState) {
        push @updated, $row->{$idField};
      } else {
        push @created, $row->{$idField};
      }
    } else {
      push @destroyed, $row->{$idField} if $row->{jcreated} <= $sinceState;
    }
  }
  return (\@created, \@updated, \@destroyed);
}

sub _check_since_state {
  my ($Self, $args, $user, $newState) = @_;
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceState']}])
    unless $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});
  return ();
}

sub _limit_changes {
  my ($Self, $data, $args, $newState_ref) = @_;
  return ($data, 0) unless $args->{maxChanges} and @$data > $args->{maxChanges};
  $data = [ sort { $a->{jmodseq} <=> $b->{jmodseq} } @$data ];
  my $next = $data->[$args->{maxChanges}];
  pop @$data while (@$data and $data->[-1]{jmodseq} == $next->{jmodseq});
  return (undef, 0) unless @$data;
  $$newState_ref = "$data->[-1]{jmodseq}";
  return ($data, 1);
}

sub begin {
  my $Self = shift;
  $Self->{db}->begin();
}

sub commit {
  my $Self = shift;
  $Self->{db}->commit();
}

sub rollback {
  my $Self = shift;
  $Self->{db}->reset();
}

sub _transError {
  my $Self = shift;
  if ($Self->{db}->in_transaction()) {
    $Self->{db}->rollback();
  }
  return @_;
}

# Domain methods are loaded from separate files below.
# All files use package JMAP::API; so all cross-domain calls work unchanged.


require JMAP::API::Preferences;
require JMAP::API::Mailbox;
require JMAP::API::Email;
require JMAP::API::Thread;
require JMAP::API::Calendar;
require JMAP::API::Contact;
require JMAP::API::Submission;
require JMAP::API::StorageNode;
require JMAP::API::MDN;

1;
