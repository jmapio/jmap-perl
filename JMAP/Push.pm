package JMAP::Push;

# RFC 8620 §7.2 push subscriptions: validation and the /set rules. Nothing here
# touches the database or the network. A subscription belongs to the user, not
# to one account, so the records live with the __accounts__ worker and delivery
# happens in the parent; both come here for the rules.

use strict;
use warnings;

use POSIX qw(strftime);
use Socket qw(AF_INET AF_INET6 inet_pton);
use Time::Local qw(timegm);

our $MAX_SUBSCRIPTIONS    = 15;
our $MAX_EXPIRES          = 90 * 86400;
our $MAX_URL_LENGTH       = 2048;
our $MAX_CLIENT_ID_LENGTH = 255;

sub parse_utcdate {
  my $date = shift;
  return undef unless defined $date and not ref $date;
  my ($y, $mo, $d, $h, $mi, $s) =
    $date =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z$/ or return undef;
  return eval { timegm($s, $mi, $h, $d, $mo - 1, $y) };
}

sub format_utcdate {
  my $time = shift;
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($time));
}

# Returns ($expires, $changed): the time to store, and whether that differs from
# what the client asked for and so has to be reported back. An unusable date
# gives an undefined $expires.
sub _clamp_expires {
  my ($raw, $now) = @_;
  my $max = $now + $MAX_EXPIRES;
  return ($max, 1) unless defined $raw;
  my $time = parse_utcdate($raw);
  return (undef, 0) unless defined $time and $time > $now;
  return $time > $max ? ($max, 1) : ($time, 0);
}

sub _is_string {
  my $value = shift;
  return (defined $value and not ref $value and length $value) ? 1 : 0;
}

sub _valid_types {
  my $types = shift;
  return 1 unless defined $types;
  return 0 unless ref $types eq 'ARRAY';
  return 0 if grep { not _is_string($_) } @$types;
  return 1;
}

sub _invalid {
  return { type => 'invalidProperties', properties => [@_] };
}

# Returns ($subscription) or (undef, $seterror).
sub validate_create {
  my ($raw, $now) = @_;
  return (undef, _invalid()) unless ref $raw eq 'HASH';

  my @bad;
  push @bad, 'deviceClientId'
    unless _is_string($raw->{deviceClientId}) and length $raw->{deviceClientId} <= $MAX_CLIENT_ID_LENGTH;
  push @bad, 'url'
    unless _is_string($raw->{url}) and length $raw->{url} <= $MAX_URL_LENGTH
      and $raw->{url} =~ m{^https://[^/?#\s]+\S*$}i;
  push @bad, 'types' unless _valid_types($raw->{types});
  # 'keys' asks for RFC 8291 encryption of every push. We don't do that, and
  # refusing beats sending plaintext to a service expecting ciphertext.
  push @bad, 'keys' if defined $raw->{keys};
  push @bad, 'verificationCode' if defined $raw->{verificationCode};
  push @bad, 'id' if exists $raw->{id};

  my ($expires) = _clamp_expires($raw->{expires}, $now);
  push @bad, 'expires' unless defined $expires;

  return (undef, _invalid(@bad)) if @bad;
  return ({
    deviceClientId => $raw->{deviceClientId},
    url            => $raw->{url},
    types          => $raw->{types},
    expires        => $expires,
  });
}

# Returns ($changes, $response) or (undef, undef, $seterror). $response is what
# /set reports for the id: null, or the properties the server changed.
sub validate_update {
  my ($raw, $sub, $now) = @_;
  return (undef, undef, _invalid()) unless ref $raw eq 'HASH';

  my (%changes, %response, @bad);
  foreach my $prop (sort keys %$raw) {
    if ($prop eq 'verificationCode') {
      if (_is_string($raw->{$prop}) and $raw->{$prop} eq $sub->{verificationCode}) {
        $changes{verified} = 1;
      }
      else {
        push @bad, $prop;
      }
    }
    elsif ($prop eq 'expires') {
      my ($expires, $changed) = _clamp_expires($raw->{$prop}, $now);
      if (defined $expires) {
        $changes{expires} = $expires;
        $response{expires} = format_utcdate($expires) if $changed;
      }
      else {
        push @bad, $prop;
      }
    }
    elsif ($prop eq 'types') {
      if (_valid_types($raw->{$prop})) {
        $changes{types} = $raw->{$prop};
      }
      else {
        push @bad, $prop;
      }
    }
    else {
      # url, keys and deviceClientId are immutable; the rest doesn't exist
      push @bad, $prop;
    }
  }

  return (undef, undef, _invalid(@bad)) if @bad;
  return (\%changes, %response ? \%response : undef);
}

# Runs one PushSubscription/set against %$mine, the caller's subscriptions by
# id. $store provides new_id, insert, update and destroy. Returns the method
# response, plus the new subscriptions that are owed a PushVerification.
sub apply_set {
  my ($set, $mine, $now, $store) = @_;
  my (%created, %notCreated, %updated, %notUpdated, @destroyed, %notDestroyed, @verify);

  my $create = ref $set->{create} eq 'HASH' ? $set->{create} : {};
  foreach my $cid (sort keys %$create) {
    my ($sub, $error) = validate_create($create->{$cid}, $now);
    $error = { type => 'overQuota' } if $sub and keys %$mine >= $MAX_SUBSCRIPTIONS;
    if ($error) {
      $notCreated{$cid} = $error;
      next;
    }
    $sub->{id} = $store->{new_id}->();
    $sub->{verificationCode} = $store->{new_id}->();
    $store->{insert}->($sub);
    $mine->{$sub->{id}} = $sub;
    $created{$cid} = { id => $sub->{id}, expires => format_utcdate($sub->{expires}) };
    push @verify, $sub;
  }

  my $update = ref $set->{update} eq 'HASH' ? $set->{update} : {};
  foreach my $id (sort keys %$update) {
    unless ($mine->{$id}) {
      $notUpdated{$id} = { type => 'notFound' };
      next;
    }
    my ($changes, $response, $error) = validate_update($update->{$id}, $mine->{$id}, $now);
    if ($error) {
      $notUpdated{$id} = $error;
      next;
    }
    $store->{update}->($id, $changes) if %$changes;
    $updated{$id} = $response;
  }

  foreach my $id (ref $set->{destroy} eq 'ARRAY' ? @{$set->{destroy}} : ()) {
    unless ($mine->{$id}) {
      $notDestroyed{$id} = { type => 'notFound' };
      next;
    }
    $store->{destroy}->($id);
    delete $mine->{$id};
    push @destroyed, $id;
  }

  return {
    response => {
      created      => %created      ? \%created      : undef,
      updated      => %updated      ? \%updated      : undef,
      destroyed    => @destroyed    ? \@destroyed    : undef,
      notCreated   => %notCreated   ? \%notCreated   : undef,
      notUpdated   => %notUpdated   ? \%notUpdated   : undef,
      notDestroyed => %notDestroyed ? \%notDestroyed : undef,
    },
    verify => \@verify,
  };
}

# What /get may show. The code stays hidden until verified: handing it out
# earlier would let a client verify a URL it never received anything at.
sub public_view {
  my ($sub, $properties) = @_;
  my %view = (
    id               => $sub->{id},
    deviceClientId   => $sub->{deviceClientId},
    verificationCode => $sub->{verified} ? $sub->{verificationCode} : undef,
    expires          => format_utcdate($sub->{expires}),
    types            => $sub->{types},
  );
  return \%view unless $properties;
  return { id => $sub->{id}, map { $_ => $view{$_} } grep { exists $view{$_} } @$properties };
}

# The part of a TypeState a subscription asked for. Null types means everything.
sub filter_changed {
  my ($changed, $types) = @_;
  return { %$changed } unless $types;
  return { map { $_ => $changed->{$_} } grep { exists $changed->{$_} } @$types };
}

# Subscription URLs come from clients, so delivery must not reach the proxy's
# own network. Anything that doesn't parse counts as not public.
sub is_public_address {
  my $ip = shift;
  return 0 unless defined $ip;

  my $v4 = inet_pton(AF_INET, $ip);
  unless ($v4) {
    my $v6 = inet_pton(AF_INET6, $ip);
    return 0 unless $v6;
    if (substr($v6, 0, 12) eq ("\0" x 10) . "\xff\xff") {
      $v4 = substr($v6, 12);
    }
    else {
      return 0 if substr($v6, 0, 15) eq "\0" x 15;  # :: and ::1
      my ($first, $second) = unpack('CC', $v6);
      return 0 if $first == 0xff;                   # multicast
      return 0 if ($first & 0xfe) == 0xfc;          # unique local
      return 0 if $first == 0xfe and ($second & 0x80) == 0x80;  # link and site local
      return 1;
    }
  }

  my ($first, $second, $third) = unpack('CCC', $v4);
  return 0 if $first == 0 or $first == 10 or $first == 127 or $first >= 224;
  return 0 if $first == 100 and $second >= 64 and $second <= 127;  # carrier-grade NAT
  return 0 if $first == 169 and $second == 254;
  return 0 if $first == 172 and $second >= 16 and $second <= 31;
  return 0 if $first == 192 and $second == 168;
  return 0 if $first == 192 and $second == 0 and $third == 0;
  return 0 if $first == 198 and ($second == 18 or $second == 19);
  return 1;
}

1;
