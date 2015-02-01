package OAuth2::Tiny;

use warnings;
use strict;

use Carp;
use URI;
use URI::QueryParam;
use HTTP::Tiny;
use JSON::XS;

sub new {
    my ($class, %args) = @_;

    croak 'usage: OAuth::Tiny->new(client_id => "...", client_secret => "...", auth_url => "...", token_url => "...", callback_url => "...", scopes => [...], auth_params => {...}, ua => ...)'
        unless (grep { $_ } qw(client_id client_secret auth_url token_url)) == 4;

    my $self = {
        client_id     => $args{client_id},
        client_secret => $args{client_secret},
        auth_url      => $args{auth_url},
        token_url     => $args{token_url},
    };

    $self->{callback_url} = $args{callback_url} // "oob";
    $self->{scopes}       = $args{scopes} if $args{scopes};
    $self->{ua}           = $args{ua} if $args{ua};

    return bless $self, $class;
}

sub start {
    my ($self, $state) = @_;

    my $uri = URI->new($self->{auth_url});
    $uri->query_param(response_type   => "code");
    $uri->query_param(client_id       => $self->{client_id});
    $uri->query_param(redirect_uri    => $self->{callback_url});
    $uri->query_param(access_type     => "offline");
    $uri->query_param(approval_prompt => "force");

    $uri->query_param(state => $state) if defined $state;

    $uri->query_param(scope => join ' ', @{$self->{scopes}}) if $self->{scopes};

    return "$uri";
}

sub finish {
    my ($self, $code) = @_;

    croak 'usage: $oauth->finish($code)'
        unless $code;

    $self->{ua} ||= HTTP::Tiny->new;

    my $form = {
        client_id     => $self->{client_id},
        client_secret => $self->{client_secret},
        redirect_uri  => $self->{callback_url},
        code          => $code,
        grant_type    => "authorization_code",
    };

    my $res = $self->{ua}->post_form($self->{token_url}, $form);

    unless ($res->{success}) {
        croak "couldn't get refresh token from $self->{token_url}: $res->{status} $res->{reason}";
    }

    my $data = decode_json($res->{content});

    croak "token error: $data->{error}" if $data->{error};

    my $ret = {
        refresh_token => $data->{refresh_token},
        access_token  => $data->{access_token},
        expires_in    => $data->{expires_in},
    };

    return $ret;
}

sub refresh {
    my ($self, $refresh_token) = @_;

    croak 'usage: $oauth->refresh($refresh_token)'
        unless $refresh_token;

    $self->{ua} ||= HTTP::Tiny->new;

    my $form = {
        client_id     => $self->{client_id},
        client_secret => $self->{client_secret},
        redirect_uri  => $self->{callback_url},
        refresh_token => $refresh_token,
        grant_type    => "refresh_token",
    };

    my $res = $self->{ua}->post_form($self->{token_url}, $form);

    unless ($res->{success}) {
        croak "couldn't get access token from $self->{token_url}: $res->{status} $res->{reason}";
    }

    my $data = decode_json($res->{content});

    croak "token error: $data->{error}" if $data->{error};

    # some providers cycle refresh tokens, so update if necessary
    $self->{token} = $data->{refresh_token} if exists $data->{refresh_token};

    my $ret = {
        refresh_token => $data->{refresh_token} // $refresh_token,
        access_token  => $data->{access_token},
        expires_in    => $data->{expires_in},
    };

    return $ret;
}

1;
