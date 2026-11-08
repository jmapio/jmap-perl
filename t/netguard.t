#!/usr/bin/perl
# JMAP::NetGuard: no connection to a private address unless allowed
use strict;
use warnings;
use Test::More;
use lib '.';
BEGIN { delete $ENV{JMAP_ALLOW_PRIVATE_BACKENDS}; $ENV{JMAP_PRIVATE_ALLOW} = '10.1.2.3, 192.168.5.0/24, fd12::/16' }
use JMAP::NetGuard;

ok(JMAP::NetGuard::allowed('8.8.8.8'), 'a public address');
ok(!JMAP::NetGuard::allowed($_), "$_ is refused") for qw(127.0.0.1 169.254.169.254 10.0.0.1 172.17.0.2 ::1 fe80::1 ::ffff:127.0.0.1);
ok(JMAP::NetGuard::allowed('10.1.2.3'), 'one JMAP_PRIVATE_ALLOW names');
ok(JMAP::NetGuard::allowed('192.168.5.77'), 'one inside a JMAP_PRIVATE_ALLOW range');
ok(!JMAP::NetGuard::allowed('192.168.6.1'), 'but not outside it');
ok(JMAP::NetGuard::allowed('fd12:3456::1'), 'IPv6 ranges too');
{ local $ENV{JMAP_ALLOW_PRIVATE_BACKENDS} = 1; ok(JMAP::NetGuard::allowed('127.0.0.1'), 'JMAP_ALLOW_PRIVATE_BACKENDS allows every address') }

JMAP::NetGuard::install();
require IO::Socket::IP;
my $s = IO::Socket::IP->new(PeerHost => '127.0.0.1', PeerPort => 9, Timeout => 2);
ok(!$s, 'installed: a socket connect to loopback fails');
like("$@ $!", qr/permission|denied|13/i, 'as refused') or diag "$@ / $!";
require HTTP::Tiny;
my $r = HTTP::Tiny->new(timeout => 2)->get('http://127.0.0.1:1/');
is($r->{status}, 599, 'HTTP::Tiny to loopback fails too');

done_testing;
