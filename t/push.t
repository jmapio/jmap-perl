#!/usr/bin/perl

use strict;
use warnings;
use Test::More;

use lib '.';

use JMAP::Push;

my $now = 1_800_000_000;
my $max = $now + $JMAP::Push::MAX_EXPIRES;

sub set_store {
  my ($log) = @_;
  my $n = 0;
  return {
    new_id  => sub { 'id' . ++$n },
    insert  => sub { push @$log, ['insert', $_[0]{id}] },
    update  => sub { push @$log, ['update', @_] },
    destroy => sub { push @$log, ['destroy', $_[0]] },
  };
}

# Dates
is(JMAP::Push::parse_utcdate('2027-01-31T12:00:00Z'), 1801396800, 'parses a UTCDate');
is(JMAP::Push::parse_utcdate('2027-01-31T12:00:00.123Z'), 1801396800, 'parses milliseconds, as JS sends them');
is(JMAP::Push::parse_utcdate('2027-02-31T12:00:00Z'), undef, 'rejects an impossible date');
is(JMAP::Push::parse_utcdate('2027-01-31T12:00:00+01:00'), undef, 'rejects a non-UTC date');
is(JMAP::Push::parse_utcdate(undef), undef, 'undef is no date');
is(JMAP::Push::format_utcdate(1801396800), '2027-01-31T12:00:00Z', 'formats a UTCDate');

# Create, with what the Bulwark app sends
my %app = (
  deviceClientId => 'abc123',
  url            => 'https://notifications.relay.bulwarkmail.org/api/push/jmap/abc123',
  types          => ['EmailDelivery'],
  expires        => JMAP::Push::format_utcdate($now + 90 * 86400),
);
my ($sub, $error) = JMAP::Push::validate_create(\%app, $now);
ok($sub, 'accepts what the app sends') or diag explain $error;
is($sub->{expires}, $max, 'keeps a 90 day expiry');

sub bad_create {
  my ($name, $prop, %change) = @_;
  my ($ok, $err) = JMAP::Push::validate_create({ %app, %change }, $now);
  ok(!$ok, "rejects $name");
  is_deeply($err, { type => 'invalidProperties', properties => [$prop] }, "$name names $prop");
}
bad_create('a plain http url', 'url', url => 'http://relay.example/x');
bad_create('a non-url', 'url', url => 'https://');
bad_create('a url with spaces', 'url', url => "https://relay.example/a b");
bad_create('an oversized url', 'url', url => 'https://relay.example/' . ('x' x 3000));
bad_create('a missing client id', 'deviceClientId', deviceClientId => undef);
bad_create('encryption keys', 'keys', keys => { p256dh => 'x', auth => 'y' });
bad_create('a preset code', 'verificationCode', verificationCode => 'x');
bad_create('types that are no list', 'types', types => 'EmailDelivery');
bad_create('an expiry in the past', 'expires', expires => JMAP::Push::format_utcdate($now - 1));
bad_create('a garbled expiry', 'expires', expires => 'soon');

($sub) = JMAP::Push::validate_create({ %app, expires => JMAP::Push::format_utcdate($now + 400 * 86400) }, $now);
is($sub->{expires}, $max, 'clamps an expiry beyond the limit');
($sub) = JMAP::Push::validate_create({ %app, expires => undef }, $now);
is($sub->{expires}, $max, 'defaults a missing expiry');
($sub) = JMAP::Push::validate_create({ %app, types => undef }, $now);
ok($sub, 'null types means everything');

# Set: create
my @log;
my %mine;
my $result = JMAP::Push::apply_set({ create => { new => \%app } }, \%mine, $now, set_store(\@log));
is($result->{response}{created}{new}{id}, 'id1', 'reports the new id, which the app reads as created.new.id');
is($result->{response}{created}{new}{expires}, JMAP::Push::format_utcdate($max), 'reports the expiry');
is($result->{response}{notCreated}, undef, 'nothing failed');
is(scalar @{$result->{verify}}, 1, 'owes one PushVerification');
is($result->{verify}[0]{url}, $app{url}, 'to the subscribed url');
ok($result->{verify}[0]{verificationCode}, 'with a code');
is($mine{id1}{verified}, undef, 'starts unverified');

# Set: verify
my $code = $mine{id1}{verificationCode};
$result = JMAP::Push::apply_set({ update => { id1 => { verificationCode => 'wrong' } } }, \%mine, $now, set_store(\@log));
is_deeply($result->{response}{notUpdated}{id1}, { type => 'invalidProperties', properties => ['verificationCode'] }, 'a wrong code is refused');
@log = ();
$result = JMAP::Push::apply_set({ update => { id1 => { verificationCode => $code } } }, \%mine, $now, set_store(\@log));
ok(exists $result->{response}{updated}{id1}, 'the right code is accepted');
is($result->{response}{updated}{id1}, undef, 'and answered with null, as nothing else changed');
is_deeply($log[0], ['update', 'id1', { verified => 1 }], 'marks it verified');

# Set: the refresh the app does on launch
@log = ();
my $later = JMAP::Push::format_utcdate($now + 80 * 86400);
$result = JMAP::Push::apply_set({ update => { id1 => { expires => $later, types => ['EmailDelivery', 'Email'] } } }, \%mine, $now, set_store(\@log));
is($result->{response}{notUpdated}, undef, 'a refresh is accepted');
is_deeply($log[0][2], { expires => $now + 80 * 86400, types => ['EmailDelivery', 'Email'] }, 'and stored');

$result = JMAP::Push::apply_set({ update => { id1 => { expires => JMAP::Push::format_utcdate($now + 400 * 86400) } } }, \%mine, $now, set_store(\@log));
is($result->{response}{updated}{id1}{expires}, JMAP::Push::format_utcdate($max), 'a clamped expiry is reported back');

for my $prop (qw(url keys deviceClientId id nonsense)) {
  $result = JMAP::Push::apply_set({ update => { id1 => { $prop => 'x' } } }, \%mine, $now, set_store(\@log));
  is_deeply($result->{response}{notUpdated}{id1}{properties}, [$prop], "$prop can't be updated");
}

$result = JMAP::Push::apply_set({ update => { other => { expires => $later } } }, \%mine, $now, set_store(\@log));
is($result->{response}{notUpdated}{other}{type}, 'notFound', "someone else's subscription isn't found");

# Set: quota
my %full = map { ("full$_" => { id => "full$_" }) } 1 .. $JMAP::Push::MAX_SUBSCRIPTIONS;
$result = JMAP::Push::apply_set({ create => { new => \%app } }, \%full, $now, set_store(\@log));
is($result->{response}{notCreated}{new}{type}, 'overQuota', 'the limit is enforced');
is(scalar @{$result->{verify}}, 0, 'and nothing is owed a verification');

# Set: destroy
@log = ();
$result = JMAP::Push::apply_set({ destroy => ['id1', 'gone'] }, \%mine, $now, set_store(\@log));
is_deeply($result->{response}{destroyed}, ['id1'], 'destroys a subscription');
is($result->{response}{notDestroyed}{gone}{type}, 'notFound', 'an unknown id is notFound');
is_deeply(\@log, [['destroy', 'id1']], 'and only touches the known one');
ok(!$mine{id1}, 'and forgets it');

# Get
my %stored = (id => 'x', deviceClientId => 'd', url => 'https://secret', verificationCode => 'code',
              verified => 0, expires => $now, types => ['EmailDelivery']);
my $view = JMAP::Push::public_view(\%stored);
ok(!exists $view->{url}, 'never shows the url');
ok(!exists $view->{keys}, 'never shows keys');
is($view->{verificationCode}, undef, 'hides the code until verified');
is(JMAP::Push::public_view({ %stored, verified => 1 })->{verificationCode}, 'code', 'shows it afterwards');
is_deeply(JMAP::Push::public_view(\%stored, ['expires']), { id => 'x', expires => JMAP::Push::format_utcdate($now) }, 'honours properties, always with id');

# Type filter
my %changed = (Email => 's1', Thread => 's1', EmailDelivery => 's1');
is_deeply(JMAP::Push::filter_changed(\%changed, ['EmailDelivery']), { EmailDelivery => 's1' }, 'keeps what was asked for');
is_deeply(JMAP::Push::filter_changed({ Email => 's1' }, ['EmailDelivery']), {}, 'nothing for a flag change, which would wake the phone for nothing');
is_deeply(JMAP::Push::filter_changed(\%changed, undef), \%changed, 'null types means everything');

# Addresses
ok(JMAP::Push::is_public_address($_), "$_ is public")
  for qw(8.8.8.8 172.15.0.1 172.32.0.1 100.63.0.1 2606:4700:4700::1111 ::ffff:8.8.8.8);
ok(!JMAP::Push::is_public_address($_), "$_ is not public")
  for qw(10.0.0.1 127.0.0.1 169.254.169.254 172.16.0.1 172.31.255.1 192.168.0.21 100.64.0.1
         0.0.0.0 224.0.0.1 198.18.0.1 192.0.0.1 ::1 :: fe80::1 fec0::1 fc00::1 fd12::1 ff02::1
         ::ffff:127.0.0.1 ::ffff:192.168.0.1 unix/ garbage);
ok(!JMAP::Push::is_public_address(undef), 'undef is not public');

done_testing();
