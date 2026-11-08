package JMAP::EventSpan;
use strict;
use warnings;

# Where in time a stored CalendarEvent can possibly be: (firststart, lastend)
# for its jevents row, so a range query (CalendarEvent/query after/before,
# Principal/getAvailability) reads the payload of only the events that might
# overlap, instead of every event in the account.
#
# The bounds are "naive" epochs: each local date-time read as if it were UTC,
# whatever its time zone.  Its real instant is within 14 hours of that, and so
# is a query bound's, so a query compares against its own naive bounds
# widened by MARGIN (overlaps()); the exact check still runs on what passes.
# Nothing here needs a time zone database, and floating events work too.
#
#   firststart  the earliest start: the event's own, any override's
#   lastend     the latest end: the last occurrence's start (or any
#               override's) plus the longest duration; UNBOUNDED for a rule
#               without an end we can find
#   (undef, undef) when the event has no usable start: never filtered out.
#
# Pure: no DB, no I/O.  t/event-span.t.

use Time::Local qw(timegm);

our $UNBOUNDED = 253402300799;   # 9999-12-31T23:59:59
our $MARGIN    = 2 * 86400;      # covers any two UTC offsets (and DST)

# A LocalDateTime (or date) as a naive epoch, or undef.
sub naive {
  my ($s) = @_;
  return undef unless defined $s && !ref $s;
  my ($y, $mo, $d, $h, $mi, $se) = $s =~ /^(\d{4})-(\d\d)-(\d\d)(?:T(\d\d):(\d\d):(\d\d))?/ or return undef;
  return eval { timegm($se // 0, $mi // 0, $h // 0, $d, $mo - 1, $y) };
}

# An ISO 8601 duration in seconds, generously (a day is 25 hours, so a DST
# change inside it is covered), or undef.
sub duration {
  my ($dur) = @_;
  return 0 unless defined $dur;
  my ($neg, $w, $d, $h, $m, $s) = $dur =~ /^([+-]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)(?:\.\d+)?S)?)?$/
    or return undef;
  return 0 if $neg eq '-';
  return (($w // 0) * 7 + ($d // 0)) * 90000 + ($h // 0) * 3600 + ($m // 0) * 60 + ($s // 0);
}

# (firststart, lastend) of a stored event payload.
sub span {
  my ($event) = @_;
  return (undef, undef) unless ref $event eq 'HASH';
  my $synthetic = do { require Text::JSCalendar; Text::JSCalendar->isSyntheticMaster($event) };
  my $basedur = duration($event->{duration}) // return (undef, undef);
  my ($first, $last);
  my $see = sub {
    my ($start, $dur) = @_;
    $first = $start if !defined $first || $start < $first;
    $last = $start + $dur if !defined $last || $start + $dur > $last;
  };

  my $rule = ref $event->{recurrenceRule} eq 'HASH' ? $event->{recurrenceRule} : undef;
  unless ($synthetic) {
    my $start = naive($event->{start}) // return (undef, undef);
    $see->($start, $basedur);
    if ($rule) {
      my $end = _rule_last($event, $rule);
      return (undef, undef) unless defined $end;   # cannot tell
      $last = $UNBOUNDED if $end == $UNBOUNDED;
      $see->($end, $basedur) unless $end == $UNBOUNDED;
    }
  }

  my $overrides = ref $event->{recurrenceOverrides} eq 'HASH' ? $event->{recurrenceOverrides} : {};
  for my $rid (keys %$overrides) {
    my $patch = $overrides->{$rid};
    next if ref $patch eq 'HASH' && $patch->{excluded};
    $patch = {} unless ref $patch eq 'HASH';
    my $dur = exists $patch->{duration} ? duration($patch->{duration}) : $basedur;
    return (undef, undef) unless defined $dur;
    # a patch may move the instance; it could also patch "start" by pointer
    for my $s ($rid, $patch->{start}) {
      next unless defined $s;
      my $n = naive($s) // return (undef, undef);
      $see->($n, $dur);
    }
  }
  return (undef, undef) unless defined $first;
  $last = $UNBOUNDED if $last > $UNBOUNDED;
  return ($first, $last);
}

# The naive start of a rule's last occurrence, $UNBOUNDED for none, undef
# when it cannot be told.
sub _rule_last {
  my ($event, $rule) = @_;
  if (defined $rule->{until}) {
    return naive($rule->{until});
  }
  return $UNBOUNDED unless defined $rule->{count};
  my $count = $rule->{count};
  no warnings "once";
  return $UNBOUNDED unless $count =~ /^\d+$/ && $count > 0 && $count <= $Text::JSCalendar::MaxOccurrences;
  # The rule alone (no overrides: an exclusion would hide the last one);
  # every occurrence found means the expansion was complete.
  my %base = (%$event, recurrenceOverrides => undef);
  my @rids = eval { Text::JSCalendar->occurrences(\%base, max => $count) };
  return $UNBOUNDED if $@ || @rids != $count;
  return naive($rids[-1]);
}

# May an event with this span overlap [$after, $before) (LocalDateTimes in
# any time zone; either undef for open)?  Arguments are what span() gave.
sub overlaps {
  my ($first, $last, $after, $before) = @_;
  return 1 unless defined $first;
  if (defined $before and defined(my $b = naive($before))) {
    return 0 if $first >= $b + $MARGIN;
  }
  if (defined $after and defined(my $a = naive($after))) {
    return 0 if $last <= $a - $MARGIN;
  }
  return 1;
}

# The same test as SQL over jevents (firststart, lastend), with its binds.
sub sql_where {
  my ($after, $before) = @_;
  my (@where, @bind);
  if (defined $before and defined(my $b = naive($before))) {
    push @where, '(firststart IS NULL OR firststart < ?)';
    push @bind, $b + $MARGIN;
  }
  if (defined $after and defined(my $a = naive($after))) {
    push @where, '(lastend IS NULL OR lastend > ?)';
    push @bind, $a - $MARGIN;
  }
  return (join(' AND ', @where), @bind);
}

1;
