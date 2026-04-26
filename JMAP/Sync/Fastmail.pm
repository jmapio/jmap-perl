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
use Email::Sender::Transport::OAuthBearerSMTP;
use OAuth2::Tiny;
use HTTP::Tiny;
use JSON::XS qw(decode_json encode_json);
use Sys::Hostname;
use JMAP::OAuth::Fastmail ();

use constant FM_AUTH_URL => JMAP::OAuth::Fastmail::AUTH_URL;
use constant FM_TOKEN_URL => JMAP::OAuth::Fastmail::TOKEN_URL;
use constant FM_REG_URL   => JMAP::OAuth::Fastmail::REG_URL;
use constant FM_SCOPES    => JMAP::OAuth::Fastmail::SCOPES;

# Per-process cache of the registered client_id (avoids re-registering on every
# access_token() call within the same worker process).
my $cached_client_id;

sub _register_client {
  # Perform RFC 7591 dynamic client registration (synchronous — called from worker).
  my $redirect_uri = ($ENV{BASEURL} || 'http://localhost:9000') . '/cb/oauth';
  my $ua  = HTTP::Tiny->new(timeout => 15);
  my $res = $ua->request('POST', FM_REG_URL, {
    headers => { 'Content-Type' => 'application/json' },
    content => JMAP::OAuth::Fastmail->registration_body($redirect_uri),
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

sub _imap_class  { 'Mail::OAuthBearerTalk' }
sub _imap_auth   { my $Self = shift; (Password => $Self->access_token()) }
sub _dav_auth    { my $Self = shift; (access_token => $Self->access_token()) }
sub _caldav_url  { $_[0]->{auth}{caldavURL}  || 'https://caldav.fastmail.com/' }
sub _carddav_url { $_[0]->{auth}{carddavURL} || 'https://carddav.fastmail.com/' }

sub _smtp_transport {
  my ($Self, $helo) = @_;
  Email::Sender::Transport::OAuthBearerSMTP->new({
    helo          => $helo,
    host          => $Self->{auth}{smtpHost} || 'smtp.fastmail.com',
    port          => $Self->{auth}{smtpPort} || 465,
    ssl           => 1,
    sasl_username => $Self->{auth}{username},
    access_token  => $Self->access_token(),
  });
}

1;
