package Email::Sender::Transport::OAuthBearerSMTP;
# ABSTRACT: send email over SMTP with RFC 7628 OAUTHBEARER SASL mechanism.
# Usage is identical to Email::Sender::Transport::GmailSMTP — pass
# sasl_username (the email address) and access_token (the OAuth bearer token).

use Moose 0.90;
extends 'Email::Sender::Transport::SMTP';

use Net::Cmd qw(CMD_OK);
use MIME::Base64 qw(encode_base64);

has access_token => (is => 'ro', isa => 'Str');

sub _smtp_client {
  my ($self) = @_;

  my $class = "Net::SMTP";
  if ($self->ssl) {
    require Net::SMTP::SSL;
    $class = "Net::SMTP::SSL";
  } else {
    require Net::SMTP;
  }

  my $smtp = $class->new($self->_net_smtp_args);
  $self->_throw("unable to establish SMTP connection") unless $smtp;

  if ($self->sasl_username && $self->access_token) {
    # RFC 7628 §3.1 initial client response: n,,[a=<authzid>,]\x01auth=Bearer <token>\x01\x01
    my $token   = $self->access_token;
    my $cmd     = "n,,\x01auth=Bearer $token\x01\x01";
    my $authstr = encode_base64($cmd, '');
    unless ($smtp->command("AUTH", "OAUTHBEARER", $authstr)->response() == CMD_OK) {
      $self->_throw('failed AUTH OAUTHBEARER', $smtp);
    }
    return $smtp;
  }

  if ($self->sasl_username) {
    $self->_throw("sasl_username but no sasl_password")
      unless defined $self->sasl_password;
    unless ($smtp->auth($self->sasl_username, $self->sasl_password)) {
      $self->_throw('failed AUTH', $smtp);
    }
  }

  return $smtp;
}

1;
