package JMAP::Dispatch;
use strict;
use warnings;

# The /copy methods the parent orchestrates. MUST stay in step with the dispatch
# table in _do_copy_call (bin/jmap-proxy.pl): a copy method missing from here is
# forwarded to a worker, whose API does not implement /copy, and the client gets
# {"type":"unknownMethod"}.
my %COPY_METHODS = map { $_ => 1 } qw(
    Blob/copy
    Email/copy
    CalendarEvent/copy
    ContactCard/copy
);

sub is_copy_method { return $COPY_METHODS{ $_[0] // '' } ? 1 : 0 }
sub copy_methods   { return sort keys %COPY_METHODS }

# Which capability selects each method. RFC 8620 §3.3: a request names the
# specifications it uses in "using"; a method only exists for a request that
# lists the capability defining it (RFC 9404 §4: methods are "selected by" a
# capability). A method whose capability is absent is answered unknownMethod,
# the same reply a server without that extension would give, which lets a
# request be filtered before any of it is run.
#
# Values are the alternatives: any one listed capability suffices. Every api_
# method in JMAP/API/*.pm MUST appear here (t/dispatch-method-capability.t
# checks), so adding a method means deciding which specification defines it.
my %METHOD_CAPABILITIES;
{
  my %by_capability = (
    # RFC 8620
    'urn:ietf:params:jmap:core' => [qw(
      Core/echo Blob/copy
      PushSubscription/get PushSubscription/set PushSubscription/changes
      ClientPreferences/get ClientPreferences/set
      UserPreferences/get UserPreferences/set
    )],
    # RFC 8621 §2-5
    'urn:ietf:params:jmap:mail' => [qw(
      Mailbox/get Mailbox/changes Mailbox/query Mailbox/queryChanges Mailbox/set
      Thread/get Thread/changes
      Email/get Email/changes Email/query Email/queryChanges Email/set
      Email/copy Email/import Email/parse
      SearchSnippet/get
    )],
    # RFC 8621 §6-7: Identity and EmailSubmission share the submission capability
    'urn:ietf:params:jmap:submission' => [qw(
      Identity/get Identity/changes Identity/set
      EmailSubmission/get EmailSubmission/changes EmailSubmission/query
      EmailSubmission/queryChanges EmailSubmission/set
    )],
    # RFC 8621 §8
    'urn:ietf:params:jmap:vacationresponse' => [qw(VacationResponse/get VacationResponse/set)],
    # RFC 9007
    'urn:ietf:params:jmap:mdn' => [qw(MDN/send MDN/parse)],
    # RFC 9425
    'urn:ietf:params:jmap:quota' => [qw(Quota/get Quota/changes Quota/query Quota/queryChanges)],
    # RFC 9670
    'urn:ietf:params:jmap:principals' => [qw(
      Principal/get Principal/changes Principal/query Principal/queryChanges Principal/set
    )],
    # draft-ietf-jmap-calendars §1.5.2
    'urn:ietf:params:jmap:principals:availability' => [qw(Principal/getAvailability)],
    # draft-ietf-jmap-calendars; Calendar/refreshSynced and CalendarPreferences
    # are proxy extensions to the same data
    'urn:ietf:params:jmap:calendars' => [qw(
      Calendar/get Calendar/changes Calendar/set Calendar/refreshSynced
      CalendarEvent/get CalendarEvent/changes CalendarEvent/query
      CalendarEvent/queryChanges CalendarEvent/set CalendarEvent/copy
      ParticipantIdentity/get ParticipantIdentity/changes ParticipantIdentity/set
      CalendarPreferences/get CalendarPreferences/set
    )],
    'urn:ietf:params:jmap:calendars:parse' => [qw(CalendarEvent/parse)],
    # RFC 9610; Contact, ContactGroup and Addressbook are the pre-RFC forms of
    # the same data the proxy still answers
    'urn:ietf:params:jmap:contacts' => [qw(
      AddressBook/get AddressBook/changes AddressBook/set
      ContactCard/get ContactCard/changes ContactCard/query
      ContactCard/queryChanges ContactCard/set ContactCard/copy
      Addressbook/get Addressbook/changes
      Contact/get Contact/changes Contact/query Contact/set
      ContactGroup/get ContactGroup/changes ContactGroup/set
    )],
    # draft-ietf-jmap-filenode
    'urn:ietf:params:jmap:filenode' => [qw(StorageNode/get StorageNode/query)],
    # RFC 9404
    'urn:ietf:params:jmap:blob' => [qw(Blob/upload Blob/get Blob/lookup)],
    # draft-ietf-jmap-blobext supersedes RFC 9404: Blob/get and Blob/lookup are
    # selected by either capability, Blob/set and Blob/convert only by blob2
    'urn:ietf:params:jmap:blob2' => [qw(Blob/set Blob/convert Blob/get Blob/lookup)],
  );
  for my $cap (sort keys %by_capability) {
    push @{ $METHOD_CAPABILITIES{$_} }, $cap for @{ $by_capability{$cap} };
  }
}

# The capabilities that select $method (any one suffices); empty if unknown.
sub method_capabilities { return @{ $METHOD_CAPABILITIES{ $_[0] // '' } || [] } }
sub known_methods       { return sort keys %METHOD_CAPABILITIES }

# undef when $method may run for a request whose "using" is the hashref
# $using (capability => true); otherwise the arrayref of capabilities the
# request would have needed to list. A method not in the table is left to
# the handler, which answers unknownMethod for names it has no code for.
sub method_capability_missing {
    my ($method, $using) = @_;
    my @caps = method_capabilities($method) or return undef;
    return undef if grep { $using && $using->{$_} } @caps;
    return \@caps;
}

# Core/echo is the only method whose arguments are not account-scoped -- it must
# echo back exactly what it was given, so never demand an accountId of it.
my %NO_ACCOUNT_METHOD = ('Core/echo' => 1);

# Validate the account ids on each call before anything is routed or rewritten.
#
# Returns { position => error_arguments } for the calls that must not be
# forwarded. RFC 8620 §3.6.2: a missing (or non-string) required argument is
# invalidArguments, and an accountId that is not one of the session's accounts
# is accountNotFound. $known is a hashref whose keys are the valid accountIds.
#
# A call may omit accountId only via a "#accountId" ResultReference, which is
# resolved later; that is left alone here. The proxy used to fill in the
# authenticated account for a missing id instead, but that hid client bugs and,
# for a delegated passthrough binding, let the upstream pick its OWN default
# (the login's primary account) -- the wrong account.
sub check_accounts {
    my ($calls, $known) = @_;
    my %errors;
    for my $pos (0 .. $#{ $calls || [] }) {
        my $call = $calls->[$pos];
        next unless ref $call eq 'ARRAY' && ref $call->[1] eq 'HASH';
        next if $NO_ACCOUNT_METHOD{ $call->[0] // '' };
        my $args   = $call->[1];
        my @fields = is_copy_method($call->[0]) ? qw(fromAccountId accountId) : qw(accountId);
        my (@missing, $unknown);
        for my $f (@fields) {
            next if exists $args->{"#$f"};
            my $v = $args->{$f};
            if (!defined $v || ref $v) { push @missing, $f; next }
            $unknown = 1 unless $known->{$v};
        }
        if (@missing)    { $errors{$pos} = { type => 'invalidArguments', arguments => \@missing } }
        elsif ($unknown) { $errors{$pos} = { type => 'accountNotFound' } }
    }
    return \%errors;
}

# Map a single method call to the accountid it targets.
sub call_account { return _call_account(@_) }

sub _call_account {
    my ($call, $default_aid) = @_;
    my $args = $call->[1] // {};
    if (is_copy_method($call->[0])) {
        return $args->{fromAccountId} // $default_aid;
    }
    return $args->{accountId} // $default_aid;
}

# Build the copy classifier used by group_batches: a copy is 'orchestrate' unless
# both sides resolve to the same passthrough upstream, in which case it is
# native-forwarded (undef) and the upstream performs the copy itself.
sub copy_router {
    my ($key_for_aid, $default_aid) = @_;
    return sub {
        my ($call) = @_;
        return undef unless is_copy_method($call->[0]);
        my $args = $call->[1] // {};
        my $fk = $key_for_aid->{ $args->{fromAccountId} // $default_aid // '' } // '';
        my $tk = $key_for_aid->{ $args->{accountId}     // $default_aid // '' } // '';
        # The /^fp:/ test also rejects the both-unknown ('' eq '') case.
        return undef if $fk eq $tk && $fk =~ /^fp:/;
        return 'orchestrate';
    };
}

# Group consecutive method calls sharing one upstream key into batches,
# preserving order. Returns [ { key => $k, calls => [ [pos, call], ... ] }, ... ].
sub group_batches {
    my ($calls, $key_for_aid, $default_aid, $copy_route) = @_;
    my @batches;
    for my $pos (0 .. $#$calls) {
        my $call = $calls->[$pos];
        my $route = $copy_route ? $copy_route->($call) : undef;
        my $key;
        if (defined $route) {
            $key = $route;   # e.g. 'orchestrate' — always its own batch
            push @batches, { key => $key, calls => [ [$pos, $call] ], isolated => 1 };
            next;
        }
        my $aid = _call_account($call, $default_aid);
        $key = $key_for_aid->{$aid} // "imap:$aid";
        if (@batches && $batches[-1]{key} eq $key && !$batches[-1]{isolated}) {
            push @{ $batches[-1]{calls} }, [$pos, $call];
        }
        else {
            push @batches, { key => $key, calls => [ [$pos, $call] ] };
        }
    }
    return \@batches;
}

# Evaluate a JMAP ResultReference path against $data. A "*" token maps the
# remaining path over each element of the current array and flattens one level.
# Returns (1, $value) or (0, undef).
sub resolve_pointer {
    my ($data, $path) = @_;
    my @tokens = split m{/}, $path, -1;
    shift @tokens;   # leading empty token from the leading "/"
    return _resolve_tokens($data, \@tokens);
}

sub _resolve_tokens {
    my ($node, $tokens) = @_;
    return (1, $node) unless @$tokens;
    my ($tok, @rest) = @$tokens;
    $tok =~ s{~1}{/}g; $tok =~ s{~0}{~}g;   # JSON Pointer unescaping

    if ($tok eq '*') {
        return (0, undef) unless ref $node eq 'ARRAY';
        my @out;
        for my $el (@$node) {
            my ($ok, $v) = _resolve_tokens($el, \@rest);
            return (0, undef) unless $ok;
            if (ref $v eq 'ARRAY') { push @out, @$v } else { push @out, $v }
        }
        return (1, \@out);
    }
    if (ref $node eq 'HASH') {
        return (0, undef) unless exists $node->{$tok};
        return _resolve_tokens($node->{$tok}, \@rest);
    }
    if (ref $node eq 'ARRAY' && $tok =~ /^\d+$/) {
        return (0, undef) unless $tok <= $#$node;
        return _resolve_tokens($node->[$tok], \@rest);
    }
    return (0, undef);
}

1;
