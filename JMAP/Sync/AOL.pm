#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::AOL;
use base qw(JMAP::Sync::Common);

use Sys::Hostname;
use Mail::GmailTalk;
use JSON::XS qw(decode_json);
use Email::Sender::Transport::GmailSMTP;
use OAuth2::Tiny;
use IO::File;

my $O;
sub O {
  unless ($O) {
    local $/;
    my $fh = IO::File->new("/home/jmap/jmap-perl/config.json", 'r');
    my $config = decode_json(<$fh>);
    close($fh);
    $O = OAuth2::Tiny->new(%{$config->{aol}});
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

sub _imap_class { 'Mail::GmailTalk' }
sub _imap_auth  { my $Self = shift; (Password => $Self->access_token()) }
sub _dav_auth   { my $Self = shift; (access_token => $Self->access_token()) }

sub _smtp_transport {
  my ($Self, $helo) = @_;
  Email::Sender::Transport::GmailSMTP->new({
    helo          => $helo,
    host          => $Self->{auth}{smtpHost},
    port          => $Self->{auth}{smtpPort},
    ssl           => 1,
    sasl_username => $Self->{auth}{username},
    access_token  => $Self->access_token(),
  });
}

1;
