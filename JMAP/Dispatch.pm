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

# Core/echo is the only method whose arguments are not account-scoped — it must
# echo back exactly what it was given, so never inject an accountId into it.
my %NO_ACCOUNT_METHOD = ('Core/echo' => 1);

sub _set_default {
    my ($args, $field, $default) = @_;
    # A "#field" ResultReference will supply this field later; leave it alone so
    # the reference still wins.
    return if exists $args->{$field} || exists $args->{"#$field"};
    $args->{$field} = $default;
}

# Spell out the account ids a call leaves implicit, in place.
#
# A JMAP call may omit accountId to mean "the account I am authenticated as".
# The proxy MUST materialise that before forwarding: the upstream would apply its
# OWN default (the login's primary account), which is the wrong account whenever
# a proxy account is bound to a delegated upstream account. Making the ids
# explicit also lets the id-rewriting map translate them.
sub apply_default_accounts {
    my ($calls, $default_aid) = @_;
    for my $call (@{ $calls || [] }) {
        next unless ref $call eq 'ARRAY' && ref $call->[1] eq 'HASH';
        next if $NO_ACCOUNT_METHOD{ $call->[0] // '' };
        my $args = $call->[1];
        if (is_copy_method($call->[0])) {
            _set_default($args, 'fromAccountId', $default_aid);
            _set_default($args, 'accountId',     $default_aid);
        }
        else {
            _set_default($args, 'accountId', $default_aid);
        }
    }
    return $calls;
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
