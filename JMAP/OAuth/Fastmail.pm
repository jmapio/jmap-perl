package JMAP::OAuth::Fastmail;

use strict;
use warnings;
use URI;
use JSON::XS qw(encode_json);

use constant AUTH_URL  => 'https://api.fastmail.com/oauth/authorize';
use constant TOKEN_URL => 'https://api.fastmail.com/oauth/refresh';
use constant REG_URL   => 'https://api.fastmail.com/oauth/register';
use constant SCOPES    => join(' ',
    'urn:ietf:params:oauth:scope:mail',
    'urn:ietf:params:oauth:scope:contacts',
    'urn:ietf:params:oauth:scope:calendars',
    'offline_access');
use constant IMAP => {
    imapHost   => 'imap.fastmail.com',  imapPort   => 993,  imapSSL    => 2,
    smtpHost   => 'smtp.fastmail.com',  smtpPort   => 465,  smtpSSL    => 2,
    caldavURL  => 'https://caldav.fastmail.com/',
    carddavURL => 'https://carddav.fastmail.com/',
};

# Returns ($redirect_url, $state_hashref).
# Caller stores $state_hashref under the state token and redirects the user.
sub auth_url_and_state {
    my ($class, %args) = @_;
    # args: client_id, email, auth_aid, baseurl, state_token, code_verifier, challenge, via
    my $auth_url = URI->new(AUTH_URL);
    $auth_url->query_param(response_type         => 'code');
    $auth_url->query_param(client_id             => $args{client_id});
    $auth_url->query_param(redirect_uri          => "$args{baseurl}/cb/oauth");
    $auth_url->query_param(scope                 => SCOPES);
    $auth_url->query_param(code_challenge        => $args{challenge});
    $auth_url->query_param(code_challenge_method => 'S256');
    $auth_url->query_param(login_hint            => $args{email}) if $args{email};
    $auth_url->query_param(state                 => $args{state_token});

    my $via = $args{via} // 'imap';
    my $state = {
        email         => $args{email},
        auth_aid      => $args{auth_aid},
        provider      => 'fastmail',
        code_verifier => $args{code_verifier},
        token_url     => TOKEN_URL,
        userinfo_url  => undef,
        client_id     => $args{client_id},
        client_secret => '',
        account_type  => ($via eq 'jmap' ? 'fastmail_jmap' : 'fastmail'),
        imap          => IMAP,
        via           => $via,
        expires       => time() + 600,
    };

    return ("$auth_url", $state);
}

# Returns the JSON body for RFC 7591 dynamic client registration.
sub registration_body {
    my ($class, $redirect_uri) = @_;
    encode_json({
        client_name              => 'jmap-proxy',
        redirect_uris            => [$redirect_uri],
        grant_types              => ['authorization_code', 'refresh_token'],
        response_types           => ['code'],
        token_endpoint_auth_method => 'none',
        scope                    => SCOPES,
    });
}

1;
