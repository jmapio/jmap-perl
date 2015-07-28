#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Gmail;
use base qw(JMAP::Sync::Common);

use Mail::GmailTalk;
use JSON::XS qw(decode_json);
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::GmailSMTP;
use Net::GmailCalendars;
use Net::GmailContacts;
use OAuth2::Tiny;
use IO::All;

my $O;
sub O {
  unless ($O) {
    my $data = io->file("/home/jmap/jmap-perl/config.json")->slurp;
    my $config = decode_json($data);
    $O = OAuth2::Tiny->new(%$config);
  }
  return $O;
}

sub access_token {
  my $Self = shift;
  unless ($Self->{access_token}) {
    my $refresh_token = $Self->{auth}{password};
    my $O = $Self->O();
    my $data = $O->refresh($refresh_token);
    $Self->{access_token} = $data->{access_token};
  }
  return $Self->{access_token};
}

sub connect_calendars {
  my $Self = shift;

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::GmailCalendars->new(
    user => $Self->{auth}{username},
    access_token => $Self->access_token(),
    url => $Self->{auth}{caldavURL},
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
    access_token => $Self->access_token(),
    url => $Self->{auth}{carddavURL},
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
    my $port = $Self->{auth}{imapPort};
    my $usessl = 1;
    $Self->{imap} = Mail::GmailTalk->new(
      Server   => $Self->{auth}{imapHost},
      Port     => $port,
      Username => $Self->{auth}{username},
      Password => $Self->access_token(),
      # not configurable right now...
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

  my $email = Email::Simple->new($rfc822);
  sendmail($email, {
    from => $Self->{auth}{username},
    transport => Email::Sender::Transport::GmailSMTP->new({
      helo => $ENV{jmaphost},
      host => $Self->{auth}{smtpHost},
      port => $Self->{auth}{smtpPort},
      ssl => 1,
      sasl_username => $Self->{auth}{username},
      access_token => $Self->access_token(),
    })
  });
}

sub imap_labels {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $labels = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->select($imapname);
  die "SELECT FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  $imap->store($uids, "x-gm-labels", "(@$labels)");
  $Self->_unselect($imap);

  $res{updated} = $uids;

  return \%res;
}


1;
