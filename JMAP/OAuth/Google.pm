package JMAP::OAuth::Google;

use strict;
use warnings;
use URI;

use constant AUTH_URL     => 'https://accounts.google.com/o/oauth2/v2/auth';
use constant TOKEN_URL    => 'https://oauth2.googleapis.com/token';
use constant USERINFO_URL => 'https://www.googleapis.com/oauth2/v3/userinfo';
use constant SCOPES       => join(' ',
    'https://mail.google.com/',
    'https://www.googleapis.com/auth/calendar',
    'https://www.googleapis.com/auth/carddav',
    'email');
use constant IMAP => {
    imapHost   => 'imap.gmail.com',  imapPort   => 993,  imapSSL    => 1,
    smtpHost   => 'smtp.gmail.com',  smtpPort   => 587,  smtpSSL    => 1,
    caldavURL  => 'https://apidata.googleusercontent.com/caldav/v2/',
    carddavURL => 'https://www.googleapis.com/.well-known/carddav',
};

# Returns ($redirect_url, $state_hashref).
# Caller stores $state_hashref under the state token and redirects the user.
sub auth_url_and_state {
    my ($class, %args) = @_;
    # args: email, auth_aid, baseurl, state_token, client_id, client_secret
    my $auth_url = URI->new(AUTH_URL);
    $auth_url->query_param(response_type => 'code');
    $auth_url->query_param(client_id     => $args{client_id});
    $auth_url->query_param(redirect_uri  => "$args{baseurl}/cb/oauth");
    $auth_url->query_param(scope         => SCOPES);
    $auth_url->query_param(access_type   => 'offline');
    $auth_url->query_param(prompt        => 'consent');
    $auth_url->query_param(login_hint    => $args{email}) if $args{email};
    $auth_url->query_param(state         => $args{state_token});

    my $state = {
        email         => $args{email},
        auth_aid      => $args{auth_aid},
        provider      => 'google',
        code_verifier => undef,
        token_url     => TOKEN_URL,
        userinfo_url  => USERINFO_URL,
        client_id     => $args{client_id},
        client_secret => $args{client_secret},
        account_type  => 'gmail',
        imap          => IMAP,
        expires       => time() + 600,
    };

    return ("$auth_url", $state);
}

1;
