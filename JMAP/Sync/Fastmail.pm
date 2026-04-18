#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Fastmail;
use base qw(JMAP::Sync::Common);

# Fastmail OAuth2 backend (draft-ietf-mailmaint-oauth-public).
# No client_id pre-registration required — we use RFC 7591 dynamic client
# registration at https://api.fastmail.com/oauth/register if FASTMAIL_CLIENT_ID
# is not set.  IMAP/SMTP use RFC 7628 OAUTHBEARER; CalDAV/CardDAV use Bearer.

use Mail::OAuthBearerTalk;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::OAuthBearerSMTP;
use Net::CalDAVTalk;
use Net::CardDAVTalk;
use OAuth2::Tiny;
use HTTP::Tiny;
use JSON::XS qw(decode_json encode_json);
use Sys::Hostname;

# Fastmail OAuth2 server metadata (from https://api.fastmail.com/.well-known/oauth-authorization-server)
use constant FM_AUTH_URL    => 'https://api.fastmail.com/oauth/authorize';
use constant FM_TOKEN_URL   => 'https://api.fastmail.com/oauth/refresh';
use constant FM_REG_URL     => 'https://api.fastmail.com/oauth/register';
use constant FM_SCOPES      => 'urn:ietf:params:oauth:scope:mail '
                             . 'urn:ietf:params:oauth:scope:contacts '
                             . 'urn:ietf:params:oauth:scope:calendars '
                             . 'offline_access';

# Per-process cache of the registered client_id (avoids re-registering on every
# access_token() call within the same worker process).
my $cached_client_id;

sub _register_client {
  # Perform RFC 7591 dynamic client registration (synchronous — called from worker).
  my $redirect_uri = ($ENV{BASEURL} || 'http://localhost:9000') . '/cb/oauth';
  my $ua  = HTTP::Tiny->new(timeout => 15);
  my $res = $ua->request('POST', FM_REG_URL, {
    headers => { 'Content-Type' => 'application/json' },
    content => encode_json({
      client_name              => 'jmap-proxy',
      redirect_uris            => [$redirect_uri],
      grant_types              => ['authorization_code', 'refresh_token'],
      response_types           => ['code'],
      token_endpoint_auth_method => 'none',
      scope                    => FM_SCOPES,
    }),
  });
  unless ($res->{success}) {
    die "Fastmail dynamic registration failed: $res->{status} $res->{reason}\n";
  }
  my $data = eval { decode_json($res->{content}) };
  $data->{client_id} or die "Fastmail registration returned no client_id: $res->{content}\n";
  return $data->{client_id};
}

sub _get_oauth {
  my $Self = shift;
  return $Self->{oauth} if $Self->{oauth};

  my $client_id = $ENV{FASTMAIL_CLIENT_ID} || $cached_client_id || _register_client();
  $cached_client_id = $client_id;

  $Self->{oauth} = OAuth2::Tiny->new(
    client_id    => $client_id,
    auth_url     => FM_AUTH_URL,
    token_url    => FM_TOKEN_URL,
    callback_url => ($ENV{BASEURL} || 'http://localhost:9000') . '/cb/oauth',
  );
  return $Self->{oauth};
}

sub access_token {
  my $Self = shift;
  unless ($Self->{access_token}) {
    my $refresh_token = $Self->{auth}{password};
    my $data = $Self->_get_oauth()->refresh($refresh_token);
    $Self->{access_token} = $data->{access_token};
  }
  return $Self->{access_token};
}

sub connect_imap {
  my $Self  = shift;
  my $force = shift;

  if ($Self->{imap} and not $force) {
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  $Self->{imap}->disconnect() if $Self->{imap};
  delete $Self->{imap};

  for (1..3) {
    $Self->{imap} = Mail::OAuthBearerTalk->new(
      Server        => $Self->{auth}{imapHost} || 'imap.fastmail.com',
      Port          => $Self->{auth}{imapPort} || 993,
      Username      => $Self->{auth}{username},
      Password      => $Self->access_token(),
      UseSSL        => 1,
      UseBlocking   => 1,
      PreserveINBOX => 1,
    );
    next unless $Self->{imap};
    $Self->{lastused} = time();
    return $Self->{imap};
  }

  die "Could not connect to Fastmail IMAP server: $@";
}

sub connect_calendars {
  my $Self = shift;

  if ($Self->{calendars}) {
    $Self->{lastused} = time();
    return $Self->{calendars};
  }

  $Self->{calendars} = Net::CalDAVTalk->new(
    user         => $Self->{auth}{username},
    access_token => $Self->access_token(),
    url          => $Self->{auth}{caldavURL} || 'https://caldav.fastmail.com/',
    expandurl    => 1,
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
    user         => $Self->{auth}{username},
    access_token => $Self->access_token(),
    url          => $Self->{auth}{carddavURL} || 'https://carddav.fastmail.com/',
    expandurl    => 1,
  );

  return $Self->{contacts};
}

sub send_email {
  my $Self     = shift;
  my $rfc822   = shift;
  my $envelope = shift;

  my %args;
  if ($envelope) {
    $args{from} = $envelope->{mailFrom}{email};
    $args{to}   = [ map { $_->{email} } @{$envelope->{rcptTo}} ];
  } else {
    $args{from} = $Self->{auth}{username};
  }

  my $helo  = $ENV{HOSTNAME} || hostname();
  my $email = Email::Simple->new($rfc822);
  sendmail($email, {
    %args,
    transport => Email::Sender::Transport::OAuthBearerSMTP->new({
      helo          => $helo,
      host          => $Self->{auth}{smtpHost} || 'smtp.fastmail.com',
      port          => $Self->{auth}{smtpPort} || 465,
      ssl           => 1,
      sasl_username => $Self->{auth}{username},
      access_token  => $Self->access_token(),
    }),
  });
}

1;
