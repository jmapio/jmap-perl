#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Standard;
use base qw(JMAP::Sync::Common);

use Mail::IMAPTalk;
use JSON::XS qw(encode_json decode_json);
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTPS;
use Net::CalDAVTalk;
use Net::CardDAVTalk;

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect \\NoInferiors);

sub connect_calendars {
  my $Self = shift;

  return unless $Self->{auth}{calurl};

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::CalDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => $Self->{auth}{calurl},
    expandurl => 1,
  );

  return $Self->{calendars};
}

sub connect_contacts {
  my $Self = shift;

  return unless $Self->{auth}{addressbookurl};

  if ($Self->{contacts}) {
    $Self->{lastused} = time();
    return $Self->{contacts};
  }

  $Self->{contacts} = Net::CardDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => $Self->{auth}{addressbookurl},
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
    my $port = 993;
    my $usessl = $port != 143;  # we use SSL for anything except default
    $Self->{imap} = Mail::IMAPTalk->new(
      Server   => $Self->{auth}{imapserver},
      Port     => $port,
      Username => $Self->{auth}{username},
      Password => $Self->{auth}{password},
      # not configurable right now...
      UseSSL   => $usessl,
      UseBlocking => $usessl,
    );
    next unless $Self->{imap};
    $Self->{lastused} = time();
    my $list = $Self->{imap}->capability()->{xlist} ? 'xlist' : 'list';
    my @folders = $Self->{imap}->$list('', '*');

    delete $Self->{folders};
    delete $Self->{labels};
    foreach my $folder (@folders) {
      my ($role) = grep { not $KNOWN_SPECIALS{lc $_} } @{$folder->[0]};
      my $name = $folder->[2];
      my $label = $role || $folder->[2];
      $Self->{folders}{$name} = [$folder->[1], $label];
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
    transport => Email::Sender::Transport::SMTPS->new({
      helo => 'proxy.jmap.io',
      host => $Self->{auth}{smtpserver},
      port => 587,
      ssl => 'starttls',
      sasl_username => $Self->{auth}{username},
      sasl_password => $Self->{auth}{password},
    }),
  });
}

1;
