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

sub _smtp_client {
  my ($self) = @_;

  my $class = "Net::SMTP";
  if ($self->ssl) {
    require Net::SMTP::SSL;
    $class = "Net::SMTP::SSL";
  } else {
    require Net::SMTP;
  }

  my $smtp = $class->new( $self->_net_smtp_args );

  $self->_throw("unable to establish SMTP connection") unless $smtp;

  if ($self->sasl_username) {
    ### begin added part
    if ($self->access_token) {
      my $user = $self->sasl_username;
      my $token = $self->access_token;
      # https://developers.google.com/gmail/xoauth2_protocol
      my $cmd = "user=$user\001auth=Bearer $token\001\001";
      my $authstr = encode_base64($cmd, '');
      unless ($smtp->command("AUTH", "XOAUTH2", $authstr)->response() == CMD_OK) {
        $self->_throw('failed AUTH', $smtp);
      }
      return $smtp;
    }
    ### end added part
    $self->_throw("sasl_username but no sasl_password")
      unless defined $self->sasl_password;

    unless ($smtp->auth($self->sasl_username, $self->sasl_password)) {
      if ($smtp->message =~ /MIME::Base64|Authen::SASL/) {
        Carp::confess("SMTP auth requires MIME::Base64 and Authen::SASL");
      }

      $self->_throw('failed AUTH', $smtp);
    }
  }

  return $smtp;
}

1;
