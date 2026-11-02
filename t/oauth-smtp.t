#!/usr/bin/perl
#
# Sending through the OAuth SMTP transports, built by the real _smtp_transport
# of each backend, against a local server speaking real TLS. smtp.gmail.com:587
# is STARTTLS and smtp.fastmail.com:465 is TLS from the first byte; a client that
# picks the wrong one can't even say hello, so the mode is what's being tested.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Socket::SSL;
use IO::Socket::SSL::Utils qw(CERT_create PEM_cert2file PEM_key2file);
use MIME::Base64 qw(decode_base64);
use POSIX ();
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use lib '.';
use JMAP::Sync::Gmail;
use JMAP::Sync::Fastmail;

my $dir = tempdir(CLEANUP => 1);
my ($ca_cert, $ca_key) = CERT_create(CA => 1, subject => { commonName => 'test CA' });
my ($cert, $key) = CERT_create(issuer => [$ca_cert, $ca_key], purpose => 'server',
                               subject => { commonName => 'localhost' },
                               subjectAltNames => [[DNS => 'localhost']]);
PEM_cert2file($ca_cert, "$dir/ca.pem");
PEM_cert2file($cert, "$dir/cert.pem");
PEM_key2file($key, "$dir/key.pem");

# The transports use the system's CAs, as they should in production.
IO::Socket::SSL::set_defaults(SSL_ca_file => "$dir/ca.pem");

my @SERVER_SSL = (SSL_server => 1, SSL_cert_file => "$dir/cert.pem", SSL_key_file => "$dir/key.pem");

sub smtp_session {
  my ($c, $mode, $opts, $log) = @_;
  my $tls = 0;
  if ($mode eq 'ssl') {
    IO::Socket::SSL->start_SSL($c, @SERVER_SSL) or return;
    $tls = 1;
  }
  print $c "220 fake ESMTP\r\n";
  while (defined(my $line = <$c>)) {
    $line =~ s/\r?\n\z//;
    if ($line =~ /^(?:EHLO|HELO)/i) {
      print $c $tls ? "250-fake\r\n250 AUTH XOAUTH2 OAUTHBEARER\r\n"
                    : "250-fake\r\n250 STARTTLS\r\n";
    }
    elsif ($line =~ /^STARTTLS/i) {
      print $c "220 go ahead\r\n";
      IO::Socket::SSL->start_SSL($c, @SERVER_SSL) or return;
      $tls = 1;
    }
    elsif ($line =~ /^AUTH (\S+) (\S+)/i) {
      print $log "auth $1 tls=$tls " . unpack('H*', decode_base64($2)) . "\n";
      print $c $opts->{refuse_auth} ? "535 no\r\n" : "235 ok\r\n";
    }
    elsif ($line =~ /^DATA/i) {
      print $c "354 go\r\n";
      while (defined(my $data = <$c>)) {
        last if $data =~ /^\.\r?\n\z/;
        print $log "data $data";
      }
      print $c "250 queued\r\n";
    }
    elsif ($line =~ /^QUIT/i) {
      print $c "221 bye\r\n";
      return;
    }
    else {
      print $c "250 ok\r\n";
    }
  }
}

# Sends one message through $class's transport to a one-connection server.
# Returns the error, if any, and what the server saw.
sub run_send {
  my ($class, $mode, $opts) = @_;
  my $listen = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5)
    or die "listen: $!";
  my $port = $listen->sockport;
  my $logfile = "$dir/smtp.log";
  unlink $logfile;

  my $pid = fork() // die "fork: $!";
  if (!$pid) {
    alarm 20;
    open my $log, '>', $logfile or die "$logfile: $!";
    $log->autoflush(1);
    my $c = $listen->accept;
    smtp_session($c, $mode, $opts || {}, $log) if $c;
    POSIX::_exit(0);
  }
  close $listen;

  my $self = bless { access_token => 'tok', access_token_expires => time() + 3600,
                     auth => { smtpHost => 'localhost', smtpPort => $port,
                               username => 'me@example.test' } }, $class;
  local $SIG{ALRM} = sub { die "timed out\n" };
  alarm 20;
  my $err = eval {
    sendmail(Email::Simple->create(
      header => [From => 'me@example.test', To => 'you@example.test', Subject => 'hello'],
      body   => "the body\n",
    ), { from => 'me@example.test', to => ['you@example.test'],
         transport => $self->_smtp_transport('client.example.test') });
    1;
  } ? undef : "$@";
  alarm 0;
  kill 'TERM', $pid;
  waitpid $pid, 0;

  open my $log, '<', $logfile or return ($err, '');
  return ($err, do { local $/; <$log> } // '');
}

sub auth_line {
  my ($seen) = @_;
  my ($mech, $tls, $hex) = ($seen // '') =~ /^auth (\S+) tls=(\d) (\S*)$/m or return ();
  return ($mech, $tls, pack('H*', $hex));
}

# --- Gmail: STARTTLS on the port every account has stored -------------------

{
  my ($err, $seen) = run_send('JMAP::Sync::Gmail', 'starttls');
  is($err, undef, 'Gmail sends over STARTTLS');
  my ($mech, $tls, $auth) = auth_line($seen);
  is($mech, 'XOAUTH2', 'Gmail logs in with XOAUTH2');
  is($tls, 1, 'the token only goes out once the connection is encrypted');
  is($auth, "user=me\@example.test\001auth=Bearer tok\001\001", 'the XOAUTH2 string is the one Google specifies');
  like($seen, qr/^data Subject: hello/m, 'the message arrives');
}

# --- Fastmail: TLS from the first byte ----------------------------------------

{
  my ($err, $seen) = run_send('JMAP::Sync::Fastmail', 'ssl');
  is($err, undef, 'Fastmail sends over direct TLS');
  my ($mech, $tls, $auth) = auth_line($seen);
  is($mech, 'OAUTHBEARER', 'Fastmail logs in with OAUTHBEARER');
  is($tls, 1, 'encrypted before the token goes out');
  is($auth, "n,,\001auth=Bearer tok\001\001", 'the OAUTHBEARER string is the RFC 7628 one');
  like($seen, qr/^data Subject: hello/m, 'the message arrives');
}

# --- a refused login is an error, not a silent success ------------------------

{
  my ($err) = run_send('JMAP::Sync::Gmail', 'starttls', { refuse_auth => 1 });
  like($err // '', qr/failed AUTH/, 'a refused token fails the send');
}

# --- a token lasts an hour, a worker runs for days ----------------------------

{
  package FakeOAuth;
  my $issued = 0;
  sub refresh { $issued++; return { access_token => "fresh$issued", expires_in => 3600 } }
}

{
  no warnings 'redefine';
  local *JMAP::Sync::Gmail::O = sub { bless {}, 'FakeOAuth' };
  my $self = bless { auth => { password => 'refresh-token' } }, 'JMAP::Sync::Gmail';
  is($self->access_token, 'fresh1', 'the first use fetches a token');
  is($self->access_token, 'fresh1', 'a valid token is reused');
  ok($self->{access_token_expires} < time() + 3600, 'renewed before Google expires it');
  $self->{access_token_expires} = time() - 1;
  is($self->access_token, 'fresh2', 'an expired token is replaced');
}

done_testing;
