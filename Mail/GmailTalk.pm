#!/usr/bin/perl -cw

package Mail::GmailTalk;
use base qw(Mail::IMAPTalk);
use MIME::Base64;

sub login {
  my $Self = shift;
  my ($User, $Token) = @_;

  # Clear cached capability responses and the like
  delete $Self->{Cache};

  my $cmd = "user=$User\001auth=Bearer $Token\001\001";
  my $string  = encode_base64($cmd, '');

  # Call standard command. Return undef if login failed
  $Self->_imap_cmd("authenticate", 0, "", "XOAUTH2", $string)
    || return undef;

  # Set to authenticated if successful
  $Self->state(Mail::IMAPTalk::Authenticated);

  return 1;
}

1;
