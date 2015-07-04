#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::ICloud;
use base qw(JMAP::DB);

use Mail::IMAPTalk;
use JSON::XS qw(encode_json decode_json);
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::GmailSMTP;
use Net::CalDAVTalk;
use Net::CardDAVTalk;

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect);

sub new {
  my $Class = shift;
  my $auth = shift;
  return bless { auth => $auth }, ref($Class) || $Class;
}

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
  }
}

sub connect_calendars {
  my $Self = shift;

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::CalDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => "https://caldav.icloud.com/",
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

  $Self->{contacts} = Net::CardDAVTalk->new(
    user => $Self->{auth}{username},
    password => $Self->{auth}{password},
    url => "https://contacts.icloud.com/",
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
    $Self->{imap} = Mail::IMAPTalk->new(
      Server   => 'imap.mail.me.com',
      Port     => $port,
      Username => $Self->{auth}{username},
      Password => $Self->{auth}{password},
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

sub get_calendars {
  my $Self = shift;
  my $talk = $Self->connect_calendars();

  my $data = $talk->GetCalendars();

  return $data;
}

sub get_events {
  my $Self = shift;
  my $Args = shift;
  my $talk = $Self->connect_calendars();

  my $data = $talk->GetEvents($Args->{href});

  return $data;
}

sub get_abooks {
  my $Self = shift;
  my $talk = $Self->connect_contacts();

  my $data = $talk->GetAddressBooks();

  return $data;
}

sub get_contacts {
  my $Self = shift;
  my $Args = shift;
  my $talk = $Self->connect_contacts();

  my $data = $talk->GetContacts($Args->{path});

  return $data;
}

sub send_email {
  my $Self = shift;
  my $rfc822 = shift;

  my $email = Email::Simple->new($rfc822);
  sendmail($email, {
    from => $Self->{auth}{username},
    transport => Email::Sender::Transport::GmailSMTP->new({
      host => 'smtp.gmail.com',
      port => 465,
      ssl => 1,
      sasl_username => $Self->{auth}{username},
      access_token => $Self->{auth}{access_token},
    })
  });
}

# read folder list from the server
sub folders {
  my $Self = shift;
  $Self->connect_imap();
  return $Self->{folders};
}

sub labels {
  my $Self = shift;
  $Self->connect_imap();
  return $Self->{labels};
}

sub fetch_status {
  my $Self = shift;
  my $justfolders = shift;

  my $imap = $Self->connect_imap();

  my $folders = $Self->folders;
  if ($justfolders) {
    my %data = map { $_ => $folders->{$_} }
               grep { exists $folders->{$_} }
               @$justfolders;
    $folders = \%data;
  }

  my $fields = "(uidvalidity uidnext highestmodseq messages)";
  my $data = $imap->multistatus($fields, sort keys %$folders);

  return $data;
}

sub fetch_folder {
  my $Self = shift;
  my $imapname = shift;
  my $state = shift || { uidvalidity => 0 };

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $r" unless (lc($r) eq 'ok' or lc($r) eq 'read-only');

  my $uidvalidity = $imap->get_response_code('uidvalidity');
  my $uidnext = $imap->get_response_code('uidnext');
  my $highestmodseq = $imap->get_response_code('highestmodseq') || 0;
  my $exists = $imap->get_response_code('exists') || 0;

  if ($state->{uidvalidity} != $uidvalidity) {
    # force a delete/recreate and resync
    $state = {
      uidvalidity => $uidvalidity.
      highestmodseq => 0,
      uidnext => 0,
      exists => 0,
    };
  }

  if ($highestmodseq and $highestmodseq == $state->{highestmodseq}) {
    $Self->log('debug', "Nothing to do for $imapname at $highestmodseq");
    return {}; # yay, nothing to do
  }

  my $changed = {};
  if ($state->{uidnext} > 1) {
    my $from = 1;
    my $to = $state->{uidnext} - 1;
    my @extra;
    push @extra, "(changedsince $state->{highestmodseq})" if $state->{highestmodseq};
    $Self->log('debug', "UPDATING $imapname: $from:$to");
    $changed = $imap->fetch("$from:$to", "(uid flags)", @extra) || {};
  }

  my $new = {};
  if ($uidnext > $state->{uidnext}) {
    my $from = $state->{uidnext};
    my $to = $uidnext - 1; # or just '*'
    $Self->log('debug', "FETCHING $imapname: $from:$to");
    $new = $imap->fetch("$from:$to", '(uid flags internaldate envelope rfc822.size)') || {};
  }

  my $alluids = undef;
  if ($state->{exists} + scalar(keys %$new) > $exists) {
    # some messages were deleted
    my $from = 1;
    my $to = $uidnext - 1;
    # XXX - you could do some clever UID vs position queries to bisect this out, but it
    # would need more data than we have here
    $Self->log('debug', "COUNTING $imapname: $from:$to (something deleted)");
    $alluids = $imap->search("UID", "$from:$to");
  }

  return {
    oldstate => $state,
    newstate => {
      highestmodseq => $highestmodseq,
      uidvalidity => $uidvalidity.
      uidnext => $uidnext,
      exists => $exists,
    },
    changed => $changed,
    new => $new,
    ($alluids ? (alluids => $alluids) : ()),
  };
}

1;
