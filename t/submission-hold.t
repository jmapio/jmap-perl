#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::ImapDB;

# FUTURERELEASE (RFC 4865 S3) on an EmailSubmission's mailFrom parameters.
my $now = 1_800_000_000;
my $max = $JMAP::Capabilities::MAX_DELAYED_SEND;
my $release = \&JMAP::ImapDB::_release_time;

is_deeply([ $release->(undef, $now) ], [], 'no parameters: no hold');
is_deeply([ $release->({}, $now) ], [], 'empty parameters: no hold');
is_deeply([ $release->({ HOLDFOR => '60' }, $now) ], [ $now + 60 ], 'HOLDFOR is seconds from now');
is_deeply([ $release->({ holdfor => '60' }, $now) ], [ $now + 60 ], 'parameter names are case-insensitive');
my ($until) = $release->({ HOLDUNTIL => '2027-01-15T08:00:00Z' }, 1_800_000_000 - 86400 * 400);
ok(!defined $until, 'HOLDUNTIL beyond maxDelayedSend is refused');

my $soon = 1_800_000_000 + 3600;
my @iso = gmtime($soon);
my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $iso[5] + 1900, $iso[4] + 1, @iso[3, 2, 1, 0]);
is_deeply([ $release->({ HOLDUNTIL => $iso }, $now) ], [ $soon ], 'HOLDUNTIL is an absolute UTC time');

for my $bad ({ HOLDFOR => '0' }, { HOLDFOR => 'soon' }, { HOLDFOR => $max + 1 },
             { HOLDUNTIL => 'tomorrow' }, { HOLDFOR => 5, HOLDUNTIL => $iso },
             { NOTIFY => 'NEVER' }, 'HOLDFOR=5') {
  my ($when, $why) = $release->($bad, $now);
  ok(!defined $when && $why, 'refused: ' . (ref $bad ? join(',', %$bad) : $bad))
    or diag $why;
}

# RFC 8621 S7: Bcc is removed from what is delivered, and nothing else is.
my $msg = "From: a\@example.com\r\nTo: b\@example.com\r\nBcc: c\@example.com\r\nSubject: x\r\n\r\nbody\r\n";
my $out = JMAP::ImapDB::_strip_bcc($msg);
unlike($out, qr/^Bcc:/mi, 'Bcc header removed');
like($out, qr/^To: b\@example\.com\r$/m, 'To kept');
like($out, qr/\r\n\r\nbody\r\n\z/, 'body kept');
is(JMAP::ImapDB::_strip_bcc("From: a\@example.com\r\n\r\nx\r\n"), "From: a\@example.com\r\n\r\nx\r\n",
   'a message without Bcc is untouched');

done_testing;
