package JMAP::CallSummary;
use strict;
use warnings;
use JSON::XS ();

# One line per method call for the log: the shape of its arguments and the
# size of its answer, without what is in them.  Turned on by JMAP_LOG_CALLS,
# between the default (method, ids, properties, time) and JMAP_DEBUG (every
# request and response body, mail and all).
#
# What may be shown is listed: values that say nothing about anyone's mail --
# dates, sizes, mailbox and calendar ids, keywords, flags, paging.  Anything
# else (search text, addresses, subjects, uids, names) is shown as its length.
# Pure: no I/O, no DB; t/call-summary.t.
#
# It must not change what it looks at: interpolating a number into a string
# makes Perl keep it as a string too, and JSON::XS then sends it as one --
# "total": "5" for 5 (RFC 8620 S5.5 says UnsignedInt).  So every value is
# copied before it is turned into text (_str).

# A copy of $v as text, leaving $v as it was.
sub _str { my $copy = $_[0]; return "$copy" }

# FilterCondition properties whose values are shown
my %SHOW = map { $_ => 1 } qw(
  inMailbox hasKeyword notKeyword allInThreadHaveKeyword someInThreadHaveKeyword
  noneInThreadHaveKeyword before after minSize maxSize hasAttachment
  inCalendar inAddressBook parentId role hasAnyRole isSubscribed
);
# ... and those that are lists, shown by how many
my %COUNT = map { $_ => 1 } qw(inMailboxOtherThan inCalendars inAddressBooks);

sub _value {
  my ($key, $v) = @_;
  return 'null' unless defined $v;
  if ($COUNT{$key}) { return ref $v eq 'ARRAY' ? '[' . @$v . ']' : '[1]' }
  if ($SHOW{$key}) {
    return ref $v eq 'ARRAY' ? '[' . @$v . ']' : ref $v ? '{}' : JSON::XS::is_bool($v) ? ($v ? 'true' : 'false') : "$v";
  }
  return ref $v eq 'ARRAY' ? '[' . @$v . ']' : ref $v eq 'HASH' ? '{}' : '<' . length("$v") . '>';
}

sub filter {
  my ($f) = @_;
  return 'null' unless defined $f;
  return '?' unless ref $f eq 'HASH';
  if (exists $f->{operator}) {
    my $conds = ref $f->{conditions} eq 'ARRAY' ? $f->{conditions} : [];
    return ($f->{operator} // '?') . '(' . join(',', map { filter($_) } @$conds) . ')';
  }
  return '{' . join(',', map { "$_=" . _value($_, $f->{$_}) } sort keys %$f) . '}';
}

sub sort_spec {
  my ($s) = @_;
  return '?' unless ref $s eq 'ARRAY';
  return '[' . join(',', map {
    ref $_ eq 'HASH'
      ? ($_->{property} // '?') . (defined $_->{keyword} ? ":$_->{keyword}" : '')
        . (defined $_->{isAscending} && !$_->{isAscending} ? ' desc' : '')
      : '?'
  } @$s) . ']';
}

# The arguments, as far as a log may say: filter, sort, window, flags, and
# how much a /set or /changes asks for.
sub args {
  my ($args) = @_;
  return '' unless ref $args eq 'HASH';
  my @out;
  push @out, 'filter=' . filter($args->{filter}) if exists $args->{filter};
  push @out, 'sort=' . sort_spec($args->{sort}) if defined $args->{sort};
  for my $k (qw(position anchorOffset limit maxChanges)) {
    push @out, "$k=" . _str($args->{$k}) if defined $args->{$k} && !ref $args->{$k};
  }
  push @out, 'anchor' if defined $args->{anchor};
  for my $k (qw(calculateTotal collapseThreads expandRecurrences fetchAllBodyValues onSuccessDestroyOriginal)) {
    push @out, $k if $args->{$k};
  }
  push @out, 'timeZone=' . _str($args->{timeZone}) if defined $args->{timeZone} && !ref $args->{timeZone};
  push @out, 'since' if defined $args->{sinceState} || defined $args->{sinceQueryState};
  for my $k (qw(create update)) {
    push @out, "$k=" . keys %{ $args->{$k} } if ref $args->{$k} eq 'HASH';
  }
  push @out, 'destroy=' . @{ $args->{destroy} } if ref $args->{destroy} eq 'ARRAY';
  push @out, map { "$_" } grep { /^#/ } sort keys %$args;   # back-references
  return join ' ', @out;
}

# The answer's size: an error's type, how many it lists, the total.
sub result {
  my (@items) = @_;
  my @out;
  for my $item (@items) {
    next unless ref $item eq 'ARRAY' && ref $item->[1] eq 'HASH';
    my ($name, $r) = @$item;
    if ($name eq 'error') { push @out, 'error=' . ($r->{type} // '?'); next }
    my @bits;
    for my $k (qw(list ids notFound added removed)) {
      push @bits, "$k=" . @{ $r->{$k} } if ref $r->{$k} eq 'ARRAY';
    }
    for my $k (qw(created updated destroyed notCreated notUpdated notDestroyed)) {
      my $v = $r->{$k};
      push @bits, "$k=" . (ref $v eq 'HASH' ? scalar keys %$v : ref $v eq 'ARRAY' ? scalar @$v : 0)
        if ref $v;
    }
    push @bits, 'total=' . _str($r->{total}) if defined $r->{total} && !ref $r->{total};
    push @bits, 'more' if $r->{hasMoreChanges};
    push @out, @items > 1 ? "$name: @bits" : "@bits";
  }
  return join '; ', @out;
}

1;
