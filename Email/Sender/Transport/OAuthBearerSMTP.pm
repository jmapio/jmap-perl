package Email::Sender::Transport::OAuthBearerSMTP;
# ABSTRACT: send email over SMTP with RFC 7628 OAUTHBEARER SASL mechanism.
# Usage is identical to Email::Sender::Transport::GmailSMTP — pass
# sasl_username (the email address) and access_token (the OAuth bearer token).

use Moose 0.90;
extends 'Email::Sender::Transport::SMTP';

use Net::Cmd qw(CMD_OK);
use MIME::Base64 qw(encode_base64);

has access_token => (is => 'ro', isa => 'Str');

# The token is the credential, but the parent refuses a sasl_username without
# a sasl_password
sub BUILDARGS {
  my ($class, @rest) = @_;
  my $arg = $class->SUPER::BUILDARGS(@rest);
  $arg->{sasl_password} //= '' if defined $arg->{access_token};
  return $arg;
}

# The parent connects and secures the connection, only the login differs
sub _maybe_auth {
  my ($self, $smtp) = @_;

  return $self->SUPER::_maybe_auth($smtp)
    unless $self->sasl_username && $self->access_token;

  # RFC 7628 §3.1 initial client response: n,,[a=<authzid>,]\x01auth=Bearer <token>\x01\x01
  my $token   = $self->access_token;
  my $cmd     = "n,,\x01auth=Bearer $token\x01\x01";
  my $authstr = encode_base64($cmd, '');
  return $smtp->command("AUTH", "OAUTHBEARER", $authstr)->response() == CMD_OK;
}

1;
