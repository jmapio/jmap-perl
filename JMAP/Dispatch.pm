package JMAP::Dispatch;
use strict;
use warnings;

# Map a single method call to the accountid it targets.
sub _call_account {
    my ($call, $default_aid) = @_;
    my $args = $call->[1] // {};
    if ($call->[0] =~ m{/copy$}) {
        return $args->{fromAccountId} // $default_aid;
    }
    return $args->{accountId} // $default_aid;
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
