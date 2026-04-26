package JMAP::OAuth::PACC;

use strict;
use warnings;
use URI;

# Returns ($redirect_url, $state_hashref) for a provider discovered via PACC
# (RFC 8414 metadata + PKCE).  Caller stores state and redirects.
sub auth_url_and_state {
    my ($class, %args) = @_;
    # args: meta (RFC 8414 hashref), email, auth_aid, baseurl, state_token,
    #       code_verifier, challenge, prefill (imap config hashref),
    #       client_id, client_secret

    my $meta   = $args{meta};
    my $scopes = join(' ', @{ $meta->{scopes_supported} // [] });
    $scopes ||= 'https://mail.google.com/';

    my $auth_url = URI->new($meta->{authorization_endpoint});
    $auth_url->query_param(response_type         => 'code');
    $auth_url->query_param(client_id             => $args{client_id});
    $auth_url->query_param(redirect_uri          => "$args{baseurl}/cb/oauth");
    $auth_url->query_param(scope                 => $scopes);
    $auth_url->query_param(code_challenge        => $args{challenge});
    $auth_url->query_param(code_challenge_method => 'S256');
    $auth_url->query_param(login_hint            => $args{email}) if $args{email};
    $auth_url->query_param(state                 => $args{state_token});

    my $state = {
        email         => $args{email},
        auth_aid      => $args{auth_aid},
        provider      => $meta->{issuer} // 'unknown',
        code_verifier => $args{code_verifier},
        token_url     => $meta->{token_endpoint},
        userinfo_url  => $meta->{userinfo_endpoint},
        client_id     => $args{client_id},
        client_secret => $args{client_secret},
        account_type  => 'imap',
        imap          => $args{prefill},
        expires       => time() + 600,
    };

    return ("$auth_url", $state);
}

1;
