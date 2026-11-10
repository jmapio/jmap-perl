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
        # created 0600 (it was written world-readable, then chmodded), under
        # a temporary name moved into place, so no one -- another process
        # starting at the same moment included -- reads half of it
        my $old_umask = umask 077;
        my $tmp = "$keyfile.$$.tmp";
        open my $fh, '>', $tmp or do { umask $old_umask; die "Cannot write $tmp: $!" };
        print $fh $_cached_key->export_key_pem('private');
        close $fh or do { umask $old_umask; die "Cannot write $tmp: $!" };
        umask $old_umask;
        rename $tmp, $keyfile or die "Cannot rename $tmp to $keyfile: $!";
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
            # OIDC Core S2: aud is the client the token was issued to, and a
            # nonce the client sent at authorization comes back
            aud            => $args{client_id} // 'tmail-web',
            (defined $args{nonce} && length $args{nonce} ? (nonce => $args{nonce}) : ()),
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
