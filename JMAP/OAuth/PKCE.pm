package JMAP::OAuth::PKCE;

use strict;
use warnings;
use MIME::Base64 qw(encode_base64);
use Digest::SHA  qw(sha256);

sub base64url {
    my $b64 = encode_base64($_[0], '');
    $b64 =~ tr|+/|-_|;
    $b64 =~ s/=+$//;
    $b64;
}

sub verifier {
    my $buf = '';
    open my $f, '<:raw', '/dev/urandom' or die "Cannot open /dev/urandom: $!";
    read $f, $buf, 32;
    close $f;
    base64url($buf);
}

sub challenge { base64url(sha256($_[0])) }

1;
