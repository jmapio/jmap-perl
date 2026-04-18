package JMAP::CredentialStore;
use strict;
use warnings;

use MIME::Base64 qw(encode_base64 decode_base64);
use JSON::XS qw(encode_json decode_json);
use HTTP::Tiny;

=head1 NAME

JMAP::CredentialStore — pluggable encrypted credential storage

=head1 SYNOPSIS

  use JMAP::CredentialStore;

  # Encrypt before writing to DB
  my $stored = JMAP::CredentialStore->encrypt($plaintext_password);

  # Decrypt after reading from DB (auto-detects backend by prefix)
  my $password = JMAP::CredentialStore->decrypt($stored_value);

=head1 BACKENDS

Backend is selected at first use based on environment variables:

  JMAP_OPENBAO_ADDR set  → OpenBao Transit engine (recommended for production)
  JMAP_SECRET_KEY set    → AES-256-GCM with a master key
  (neither)              → plaintext with a startup warning

Ciphertext format on disk:
  enc1:<base64(12-byte-nonce + ciphertext + 16-byte-GCM-tag)>  — AES-GCM
  vault:v1:...                                                  — OpenBao Transit
  (anything else)                                               — legacy plaintext

Decryption auto-detects the format, so data can be read regardless of which
backend is currently configured (useful during backend migrations).

=head1 GENERATING A SECRET KEY

  openssl rand -hex 32

Set the result as JMAP_SECRET_KEY.  Keep it out of the data volume — it belongs
in Docker secrets, a .env file, or your deployment's secrets manager.

=head1 OPENBAO SETUP

  docker run -d --name openbao \
    -e VAULT_DEV_ROOT_TOKEN_ID=mytoken \
    -p 8200:8200 quay.io/openbao/openbao:latest

  export VAULT_ADDR=http://localhost:8200
  export VAULT_TOKEN=mytoken
  bao secrets enable transit
  bao write transit/keys/jmap-credentials type=aes256-gcm96

Then set for the JMAP proxy:
  JMAP_OPENBAO_ADDR=http://openbao:8200
  JMAP_OPENBAO_TOKEN=mytoken          # static token
  # OR for AppRole (recommended):
  JMAP_OPENBAO_ROLE_ID=...
  JMAP_OPENBAO_SECRET_ID=...
  JMAP_OPENBAO_MOUNT=transit          # default
  JMAP_OPENBAO_KEY=jmap-credentials   # default

=cut

# Lazily-initialised singletons, keyed by backend type.
# Separate singletons let us decrypt enc1: data even when the active backend is OpenBao,
# which is needed during a migration.
my (%_backends);

sub _aes_backend {
    $_backends{aes} //= JMAP::CredentialStore::_AESGCM->new();
}

sub _bao_backend {
    $_backends{bao} //= JMAP::CredentialStore::_OpenBao->new();
}

sub _active_backend {
    if ($ENV{JMAP_OPENBAO_ADDR}) {
        return _bao_backend();
    }
    if ($ENV{JMAP_SECRET_KEY}) {
        return _aes_backend();
    }
    unless ($_backends{warned}++) {
        warn "JMAP::CredentialStore: no encryption backend configured.\n";
        warn "  Set JMAP_SECRET_KEY (run: openssl rand -hex 32) or JMAP_OPENBAO_ADDR.\n";
        warn "  Credentials will be stored in plaintext.\n";
    }
    $_backends{plain} //= JMAP::CredentialStore::_Plaintext->new();
}

# Encrypt a credential for storage.  Returns the ciphertext string.
# Passing undef or empty string returns the value unchanged.
sub encrypt {
    my (undef, $plaintext) = @_;
    return $plaintext unless defined $plaintext && length $plaintext;
    return _active_backend()->encrypt($plaintext);
}

# Decrypt a stored credential.  Auto-detects the backend from the stored prefix,
# so enc1: values can always be decrypted even if the active backend is OpenBao.
sub decrypt {
    my (undef, $value) = @_;
    return $value unless defined $value && length $value;
    if ($value =~ /^enc1:/) {
        return _aes_backend()->decrypt($value);
    }
    if ($value =~ /^vault:/) {
        return _bao_backend()->decrypt($value);
    }
    return $value;  # legacy plaintext
}

# True if the value looks like it has already been encrypted.
sub is_encrypted {
    my (undef, $value) = @_;
    return defined $value && $value =~ /^(?:enc1:|vault:)/;
}

# Reset cached backends (for testing).
sub reset { %_backends = () }

# ─── Plaintext (no-op) ────────────────────────────────────────────────────────

package JMAP::CredentialStore::_Plaintext;
sub new     { bless {}, shift }
sub encrypt { $_[1] }
sub decrypt { $_[1] }

# ─── AES-256-GCM ──────────────────────────────────────────────────────────────

package JMAP::CredentialStore::_AESGCM;

use MIME::Base64 qw(encode_base64 decode_base64);

sub new {
    my ($class) = @_;
    my $hex = $ENV{JMAP_SECRET_KEY}
        or die "JMAP_SECRET_KEY not set\n";

    my $key;
    if ($hex =~ /^[0-9a-fA-F]{64}$/) {
        $key = pack 'H*', $hex;          # 64 hex chars → 32 raw bytes
    } else {
        require Digest::SHA;
        $key = Digest::SHA::sha256($hex); # passphrase → 32-byte derived key
    }
    return bless { key => $key }, $class;
}

sub encrypt {
    my ($self, $plaintext) = @_;
    require Crypt::AuthEnc::GCM;
    my $nonce = '';
    open my $fh, '<:raw', '/dev/urandom' or die "Cannot open /dev/urandom: $!";
    read $fh, $nonce, 12;
    close $fh;
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $self->{key}, $nonce);
    my $ct  = $ae->encrypt_add($plaintext);
    my $tag = $ae->encrypt_done();
    return 'enc1:' . encode_base64($nonce . $ct . $tag, '');
}

sub decrypt {
    my ($self, $stored) = @_;
    require Crypt::AuthEnc::GCM;
    $stored =~ s/^enc1://;
    my $raw   = decode_base64($stored);
    my $nonce = substr($raw,  0, 12);
    my $tag   = substr($raw, -16);
    my $ct    = substr($raw,  12, length($raw) - 28);
    my $ae    = Crypt::AuthEnc::GCM->new('AES', $self->{key}, $nonce);
    my $pt    = $ae->decrypt_add($ct);
    $ae->decrypt_done($tag)
        or die "JMAP::CredentialStore: AES-GCM authentication tag mismatch — wrong key or corrupted data\n";
    return $pt;
}

# ─── OpenBao / Vault Transit ─────────────────────────────────────────────────

package JMAP::CredentialStore::_OpenBao;

use MIME::Base64 qw(encode_base64 decode_base64);
use JSON::XS qw(encode_json decode_json);
use HTTP::Tiny;

sub new {
    my ($class) = @_;
    my $addr = $ENV{JMAP_OPENBAO_ADDR}
        or die "JMAP_OPENBAO_ADDR not set\n";
    $addr =~ s{/+$}{};
    return bless {
        addr  => $addr,
        mount => $ENV{JMAP_OPENBAO_MOUNT} || 'transit',
        key   => $ENV{JMAP_OPENBAO_KEY}   || 'jmap-credentials',
        _tok  => undef,
    }, $class;
}

# Return a valid Vault/OpenBao token, authenticating via AppRole if needed.
sub _token {
    my ($self) = @_;
    return $self->{_tok} if $self->{_tok};

    if (my $t = $ENV{JMAP_OPENBAO_TOKEN}) {
        $self->{_tok} = $t;
        return $t;
    }

    my $role_id   = $ENV{JMAP_OPENBAO_ROLE_ID}
        or die "No JMAP_OPENBAO_TOKEN or JMAP_OPENBAO_ROLE_ID set\n";
    my $secret_id = $ENV{JMAP_OPENBAO_SECRET_ID}
        or die "JMAP_OPENBAO_SECRET_ID not set\n";

    my $ua   = HTTP::Tiny->new(timeout => 10);
    my $resp = $ua->request('POST', "$self->{addr}/v1/auth/approle/login", {
        headers => { 'Content-Type' => 'application/json' },
        content => encode_json({ role_id => $role_id, secret_id => $secret_id }),
    });
    die "OpenBao AppRole login failed ($resp->{status} $resp->{reason})\n"
        unless $resp->{success};
    my $data = decode_json($resp->{content});
    $self->{_tok} = $data->{auth}{client_token}
        or die "No client_token in OpenBao AppRole response\n";
    return $self->{_tok};
}

sub _api {
    my ($self, $method, $path, $body) = @_;
    my $ua = HTTP::Tiny->new(timeout => 10);
    my %opts = (
        headers => {
            'X-Vault-Token' => $self->_token(),
            'Content-Type'  => 'application/json',
        },
    );
    $opts{content} = encode_json($body) if $body;

    my $resp = $ua->request($method, "$self->{addr}/v1/$path", \%opts);

    # 403 may mean token expired — invalidate and retry once
    if ($resp->{status} == 403) {
        $self->{_tok} = undef;
        $opts{headers}{'X-Vault-Token'} = $self->_token();
        $resp = $ua->request($method, "$self->{addr}/v1/$path", \%opts);
    }

    die "OpenBao $method $path failed ($resp->{status} $resp->{reason})\n"
        unless $resp->{success};
    return decode_json($resp->{content});
}

sub encrypt {
    my ($self, $plaintext) = @_;
    my $b64  = encode_base64($plaintext, '');
    my $resp = $self->_api('POST', "$self->{mount}/encrypt/$self->{key}",
        { plaintext => $b64 });
    return $resp->{data}{ciphertext};  # already looks like "vault:v1:..."
}

sub decrypt {
    my ($self, $ciphertext) = @_;
    my $resp = $self->_api('POST', "$self->{mount}/decrypt/$self->{key}",
        { ciphertext => $ciphertext });
    return decode_base64($resp->{data}{plaintext});
}

1;
