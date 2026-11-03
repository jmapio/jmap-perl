#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Gmail;
use base qw(JMAP::Sync::Common);

use Sys::Hostname;
use Mail::GmailTalk;
use Email::Sender::Transport::GmailSMTP;
use OAuth2::Tiny;

my $O;
sub O {
  unless ($O) {
    my $client_id     = $ENV{GOOGLE_CLIENT_ID}
      or die "GOOGLE_CLIENT_ID environment variable not set\n";
    my $client_secret = $ENV{GOOGLE_CLIENT_SECRET}
      or die "GOOGLE_CLIENT_SECRET environment variable not set\n";
    my $redirect_uri  = $ENV{GOOGLE_REDIRECT_URI}
      || ($ENV{BASEURL} || 'http://localhost:9000') . '/cb/oauth';
    $O = OAuth2::Tiny->new(
      client_id     => $client_id,
      client_secret => $client_secret,
      auth_url      => 'https://accounts.google.com/o/oauth2/v2/auth',
      token_url     => 'https://oauth2.googleapis.com/token',
      callback_url  => $redirect_uri,
      scopes        => [
        'https://mail.google.com/',
        'https://www.googleapis.com/auth/calendar',
        'https://www.googleapis.com/auth/carddav',
        'email',
      ],
    );
  }
  return $O;
}

sub access_token { my $Self = shift; $Self->_cached_access_token(sub { $Self->O() }) }

sub _imap_class { 'Mail::GmailTalk' }
sub _imap_auth  { my $Self = shift; (Password => $Self->access_token()) }
sub _dav_auth   { my $Self = shift; (access_token => $Self->access_token()) }

# Messages name their labels in X-GM-LABELS the way XLIST names the folders:
# \Inbox, \AllMail, \Starred, \Spam. LIST says \All, \Flagged and \Junk instead,
# and nothing at all on INBOX, so a folder listed that way matches no message,
# and without \AllMail the sync has nothing to read.
my %XLIST_LABEL = ('\\all' => '\\AllMail', '\\flagged' => '\\Starred', '\\junk' => '\\Spam');

sub folders {
  my $Self = shift;
  my $data = $Self->SUPER::folders(@_);
  my $folders = $data->[1];
  foreach my $name (keys %$folders) {
    my $label = $folders->{$name}[1];
    $label = $XLIST_LABEL{lc $label} // $label;
    $label = '\\Inbox' if uc $name eq 'INBOX' and $label !~ /^\\/;
    $folders->{$name}[1] = $label;
  }
  return $data;
}

sub _smtp_transport {
  my ($Self, $helo) = @_;
  Email::Sender::Transport::GmailSMTP->new({
    helo          => $helo,
    host          => $Self->{auth}{smtpHost},
    port          => $Self->{auth}{smtpPort},
    # smtp.gmail.com: STARTTLS on 587, the port accounts store; TLS on 465
    ssl           => (($Self->{auth}{smtpPort} // 587) == 465 ? 'ssl' : 'starttls'),
    sasl_username => $Self->{auth}{username},
    access_token  => $Self->access_token(),
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
