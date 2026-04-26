package JMAP::OAuth::OIDC;

use strict;
use warnings;
use Crypt::PK::RSA;
use Crypt::JWT qw(encode_jwt);

my $_cached_key;

# Load or generate the RSA signing key.  Result is cached per process.
sub rsa_key {
    my ($class, $keyfile) = @_;
    return $_cached_key if $_cached_key;
    if (-f $keyfile) {
        $_cached_key = Crypt::PK::RSA->new($keyfile);
    } else {
        $_cached_key = Crypt::PK::RSA->new();
        $_cached_key->generate_key(256);  # 256 bytes = 2048-bit
        open my $fh, '>', $keyfile or die "Cannot write $keyfile: $!";
        print $fh $_cached_key->export_key_pem('private');
        close $fh;
        chmod 0600, $keyfile;
    }
    return $_cached_key;
}

# Build a signed RS256 id_token JWT.
sub id_token {
    my ($class, %args) = @_;
    # args: aid, email, baseurl, key
    my $now = time();
    encode_jwt(
        payload => {
            iss            => $args{baseurl},
            sub            => $args{aid},
            aud            => 'tmail-web',
            iat            => $now,
            exp            => $now + 3600,
            email          => $args{email},
            email_verified => JSON::true,
        },
        alg           => 'RS256',
        key           => $args{key},
        extra_headers => { kid => 'jmap-proxy-1' },
    );
}

1;
