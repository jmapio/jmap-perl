#!/usr/bin/perl

use strict;
use warnings;
use Test::More;

use lib '.';

use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Socket::SSL;
use IO::Socket::SSL::Utils;
use POSIX ();

BEGIN { $ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1) }

use JMAP::ImapDB;
use JMAP::Sync::Standard;

# The bug under test is a read that never returns, so a hang has to fail the test
alarm 60;

$ENV{IGNORE_INVALID_CERT} = 1;
$JMAP::Sync::Common::IMAP_TIMEOUT = 1;
$SIG{__WARN__} = sub { };

my ($cert, $key) = CERT_create(CA => 1, subject => { CN => 'localhost' });

# Answers everything with OK except NOOP and EXAMINE, where the connection
# stays open and goes silent, the way one does when the network between us
# breaks.
sub fake_imap {
  my ($tls) = @_;
  my $listen = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "listen: $!";
  my $pid = fork() // die "fork: $!";
  return ($pid, $listen->sockport) if $pid;

  alarm 60;  # fork clears the parent's, and a failing test mustn't leave this behind
  my @silent;
  while (my $client = $listen->accept) {
    if ($tls) {
      IO::Socket::SSL->start_SSL($client, SSL_server => 1, SSL_cert => $cert, SSL_key => $key) or next;
    }
    print $client "* OK ready\r\n";
    while (my $line = <$client>) {
      my ($tag, $cmd) = split ' ', $line;
      if (lc $cmd eq 'noop' or lc $cmd eq 'examine') {
        push @silent, $client;
        last;
      }
      print $client "* CAPABILITY IMAP4rev1\r\n" if lc $cmd eq 'capability';
      print $client "$tag OK done\r\n";
    }
  }
  POSIX::_exit(0);
}

foreach my $tls (0, 1) {
  my $name = $tls ? 'tls' : 'plain';
  my ($pid, $port) = fake_imap($tls);

  my $sync = JMAP::Sync::Standard->new({
    imapHost => '127.0.0.1',
    imapPort => $port,
    imapSSL  => $tls ? 2 : 1,
    username => 'user',
    password => 'secret',
  });
  my $db = bless { backend => $sync }, 'JMAP::ImapDB';

  ok($sync->connect_imap(), "$name: reads the greeting and logs in");
  ok(!$sync->connection_lost(), "$name: a working connection isn't lost");

  ok(!eval { $db->backend_cmd('imap_noop'); 1 }, "$name: a silent connection fails the command");
  like($@, qr/IMAP connection lost during imap_noop/, "$name: and says so");
  ok(!$sync->{imap}, "$name: the dead connection is gone");

  ok($sync->connect_imap(), "$name: the next command connects again");

  # A command that dies on the broken read itself ("EXAMINE FAILED") must
  # still drop the connection, or the next command would find it dead too.
  ok(!eval { $db->backend_cmd('imap_fetch', 'INBOX', { uidvalidity => 1 }, {}); 1 },
     "$name: a command that dies on the silent connection fails");
  ok(!$sync->{imap}, "$name: and the dead connection is gone all the same");
  ok($sync->connect_imap(), "$name: so the next command connects again");

  kill 'KILL', $pid;
  waitpid($pid, 0);
}

done_testing();
