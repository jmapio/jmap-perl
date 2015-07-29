#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Standard;
use base qw(JMAP::Sync::Common);

use Mail::IMAPTalk;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTPS;
use Net::CalDAVTalk;
use Net::CardDAVTalk;

sub connect_calendars {
  my $Self = shift;

  return unless $Self->{auth}{caldavURL};

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::CalDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => $Self->{auth}{caldavURL},
    expandurl => 1,
  );

  return $Self->{calendars};
}

sub connect_contacts {
  my $Self = shift;

  return unless $Self->{auth}{carddavURL};

  if ($Self->{contacts}) {
    $Self->{lastused} = time();
    return $Self->{contacts};
  }

  $Self->{contacts} = Net::CardDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => $Self->{auth}{carddavURL},
    expandurl => 1,
  );

  return $Self->{contacts};
}

sub connect_imap {
  my $Self = shift;
  my $force = shift;

  if ($Self->{imap} and not $force) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  $Self->{imap}->disconnect() if $Self->{imap};
  delete $Self->{imap};

  for (1..3) {
    my $usessl = $Self->{auth}{imapSSL} - 1; # IDs for Mail::IMAPTalk are one lower than our internal format
    $Self->{imap} = Mail::IMAPTalk->new(
      Server   => $Self->{auth}{imapHost},
      Port     => $Self->{auth}{imapPort},
      Username => $Self->{auth}{username},
      Password => $Self->{auth}{password},
      UseSSL   => $usessl,
      UseBlocking => $usessl,
    );
    next unless $Self->{imap};
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  die "Could not connect to IMAP server: $@";
}


sub send_email {
  my $Self = shift;
  my $rfc822 = shift;

  my $ssl;
  $ssl = 'ssl' if $Self->{auth}{smtpSSL} == 2;
  $ssl = 'starttls' if $Self->{auth}{smtpSSL} == 3;
  my $email = Email::Simple->new($rfc822);
  my $detail = {
      helo => $ENV{jmaphost},
      host => $Self->{auth}{smtpHost},
      port => $Self->{auth}{smtpPort},
      ssl => $ssl,
      sasl_username => $Self->{auth}{username},
      sasl_password => $Self->{auth}{password},
  };
  sendmail($email, {
    from => $Self->{auth}{username},
    transport => Email::Sender::Transport::SMTPS->new($detail),
  });
}

1;
