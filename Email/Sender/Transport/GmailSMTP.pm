package Email::Sender::Transport::GmailSMTP;
# ABSTRACT: send email over SMTP with google oauth

use Moose 0.90;
extends 'Email::Sender::Transport::SMTP';

use Net::Cmd qw(CMD_OK);
use MIME::Base64 qw(encode_base64);

#pod =head1 DESCRIPTION
#pod
#pod This transport is used to send email over SMTP authenticating against gmail
#pod specific oauth2.  Read the documentation for Email::Sender::Transport::SMTP
#pod for usage instructions.  You must still provide a sasl_username to
#pod authenticate.
#pod
#pod =head1 ATTRIBUTES
#pod
#pod The following additional attributes may be passed to the constructor:
#pod
#pod =over 4
#pod
#pod =item C<access_token>: the OAuth2 access token to use.
#pod
#pod =cut

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

  my $user = $self->sasl_username;
  my $token = $self->access_token;
  # https://developers.google.com/gmail/xoauth2_protocol
  my $cmd = "user=$user\001auth=Bearer $token\001\001";
  my $authstr = encode_base64($cmd, '');
  return $smtp->command("AUTH", "XOAUTH2", $authstr)->response() == CMD_OK;
}

1;
