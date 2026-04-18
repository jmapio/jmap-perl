package OAuth2::Tiny;

use warnings;
use strict;

use Carp;
use URI;
use URI::QueryParam;
use HTTP::Tiny;
use JSON::XS;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha256);

sub new {
    my ($class, %args) = @_;

    croak 'usage: OAuth::Tiny->new(client_id => "...", auth_url => "...", token_url => "...", ...)'
        unless $args{client_id} && $args{auth_url} && $args{token_url};

    my $self = {
        client_id     => $args{client_id},
        client_secret => $args{client_secret} // '',  # optional for public clients
        auth_url      => $args{auth_url},
        token_url     => $args{token_url},
    };

    $self->{callback_url} = $args{callback_url} // "oob";
    $self->{scopes}       = $args{scopes} if $args{scopes};
    $self->{ua}           = $args{ua} if $args{ua};

    return bless $self, $class;
}

sub _pkce_verifier {
    my $buf = '';
    open my $fh, '<:raw', '/dev/urandom' or die "Cannot open /dev/urandom: $!";
    read $fh, $buf, 32;
    close $fh;
    my $b64 = encode_base64($buf, '');
    $b64 =~ tr|+/|-_|;
    $b64 =~ s/=+$//;
    return $b64;
}

sub _pkce_challenge {
    my ($verifier) = @_;
    my $hash = sha256($verifier);
    my $b64  = encode_base64($hash, '');
    $b64 =~ tr|+/|-_|;
    $b64 =~ s/=+$//;
    return $b64;
}

# start($state) — returns ($url) normally, or ($url, $code_verifier) if pkce=>1 was passed to new().
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

    if ($self->{pkce}) {
        my $verifier  = _pkce_verifier();
        my $challenge = _pkce_challenge($verifier);
        $uri->query_param(code_challenge        => $challenge);
        $uri->query_param(code_challenge_method => 'S256');
        return ("$uri", $verifier);
    }

    return "$uri";
}

sub finish {
    my ($self, $code) = @_;

    croak 'usage: $oauth->finish($code)'
        unless $code;

    $self->{ua} ||= HTTP::Tiny->new;

    my $form = {
        client_id    => $self->{client_id},
        redirect_uri => $self->{callback_url},
        code         => $code,
        grant_type   => "authorization_code",
    };
    $form->{client_secret} = $self->{client_secret} if $self->{client_secret};
    $form->{code_verifier} = $_[2] if defined $_[2];  # PKCE

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
        redirect_uri  => $self->{callback_url},
        refresh_token => $refresh_token,
        grant_type    => "refresh_token",
    };
    $form->{client_secret} = $self->{client_secret} if $self->{client_secret};

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
