package Mail::OAuthBearerTalk;
# IMAP client that authenticates via RFC 7628 OAUTHBEARER SASL mechanism.
# Usage is identical to Mail::IMAPTalk — pass Username and Password (where
# Password is the OAuth Bearer access token) to new().
use base qw(Mail::IMAPTalk);
use MIME::Base64 qw(encode_base64);

sub login {
  my ($Self, $User, $Token) = @_;
  delete $Self->{Cache};
  # RFC 7628 §3.1 initial client response:  n,,[a=<authzid>,]\x01auth=Bearer <token>\x01\x01
  my $cmd    = "n,,\x01auth=Bearer $Token\x01\x01";
  my $string = encode_base64($cmd, '');
  $Self->_imap_cmd("authenticate", 0, "", "OAUTHBEARER", $string)
    || return undef;
  $Self->state(Mail::IMAPTalk::Authenticated);
  return 1;
}

1;
