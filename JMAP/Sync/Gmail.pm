#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Gmail;
use base qw(JMAP::Sync::Common);

use Mail::GmailTalk;
use JSON::XS qw(encode_json decode_json);
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::GmailSMTP;
use Net::GmailCalendars;
use Net::GmailContacts;

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect);

sub connect_calendars {
  my $Self = shift;

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::GmailCalendars->new(
    user => $Self->{auth}{username},
    access_token => $Self->{auth}{access_token},
    url => "https://apidata.googleusercontent.com/caldav/v2",
    expandurl => 1,
  );

  return $Self->{calendars};
}

sub connect_contacts {
  my $Self = shift;

  if ($Self->{contacts}) {
    $Self->{lastused} = time();
    return $Self->{contacts};
  }

  $Self->{contacts} = Net::GmailContacts->new(
    user => $Self->{auth}{username},
    access_token => $Self->{auth}{access_token},
    url => "https://www.googleapis.com/.well-known/carddav",
    expandurl => 1,
  );

  return $Self->{contacts};
}

sub connect_imap {
  my $Self = shift;

  if ($Self->{imap}) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  for (1..3) {
    $Self->log('debug', "Looking for server for $Self->{auth}{username}");
    my $port = 993;
    my $usessl = $port != 143;  # we use SSL for anything except default
    $Self->log('debug', "getting imaptalk");
    $Self->{imap} = Mail::GmailTalk->new(
      Server   => 'imap.gmail.com',
      Port     => $port,
      Username => $Self->{auth}{username},
      Password => $Self->{auth}{access_token},
      # not configurable right now...
      UseSSL   => $usessl,
      UseBlocking => $usessl,
    );
    next unless $Self->{imap};
    $Self->log('debug', "Connected as $Self->{auth}{username}");
    $Self->{lastused} = time();
    my @folders = $Self->{imap}->xlist('', '*');

    delete $Self->{folders};
    delete $Self->{labels};
    foreach my $folder (@folders) {
      my ($role) = grep { not $KNOWN_SPECIALS{lc $_} } @{$folder->[0]};
      my $name = $folder->[2];
      my $label = $role || $folder->[2];
      $Self->{folders}{$name} = $label;
      $Self->{labels}{$label} = $name;
    }
    return $Self->{imap};
  }

  die "Could not connect to IMAP server: $@";
}

sub send_email {
  my $Self = shift;
  my $rfc822 = shift;

  my $email = Email::Simple->new($rfc822);
  sendmail($email, {
    from => $Self->{auth}{username},
    transport => Email::Sender::Transport::GmailSMTP->new({
      helo => 'proxy.jmap.io',
      host => 'smtp.gmail.com',
      port => 465,
      ssl => 1,
      sasl_username => $Self->{auth}{username},
      access_token => $Self->{auth}{access_token},
    })
  });
}

sub update_folder {
  my $Self = shift;
  my $imapname = shift;
  my $state = shift;

  return $Self->SUPER::update_folder($imapname, $state, ['x-gm-labels'], ['x-gm-msgid', 'x-gm-thrid']);
}
