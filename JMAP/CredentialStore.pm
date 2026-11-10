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

  # Encrypt before writing to DB; the context names where the value lives,
  # and decryption needs the same one (a ciphertext copied elsewhere fails)
  my $ctx    = JMAP::CredentialStore::context($accountid, 'iserver.password');
  my $stored = JMAP::CredentialStore->encrypt($plaintext_password, $ctx);

  # Decrypt after reading from DB (auto-detects backend by prefix)
  my $password = JMAP::CredentialStore->decrypt($stored_value, $ctx);

=head1 BACKENDS

Backend is selected at first use based on environment variables:

  JMAP_OPENBAO_ADDR set  → OpenBao Transit engine (recommended for production)
  JMAP_SECRET_KEY set    → AES-256-GCM with a master key (64 hex characters)
  (neither)              → refused, unless JMAP_ALLOW_PLAINTEXT_CREDENTIALS=1
                           says plaintext is meant (a test server)

Ciphertext format on disk:
  enc2:<base64(12-byte-nonce + ciphertext + 16-byte-GCM-tag)>  — AES-GCM
  vault:v1:...                                                  — OpenBao Transit
  (anything else)                                               — plaintext

Both encrypt with associated data naming the account and field (context()),
so a value moved to another account or field does not decrypt.  The AES key
and the MAC key are derived from JMAP_SECRET_KEY with HKDF-SHA256, apart.
enc1: (one key for both, derived from a passphrase by a single SHA-256, no
associated data) is no longer read: such an account is set up again.
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
    die "JMAP::CredentialStore: no encryption configured: set JMAP_SECRET_KEY (openssl rand -hex 32)"
      . " or JMAP_OPENBAO_ADDR, or JMAP_ALLOW_PLAINTEXT_CREDENTIALS=1 to store credentials in plaintext\n"
        unless $ENV{JMAP_ALLOW_PLAINTEXT_CREDENTIALS};
    unless ($_backends{warned}++) {
        warn "JMAP::CredentialStore: JMAP_ALLOW_PLAINTEXT_CREDENTIALS is set: credentials are stored in plaintext\n";
    }
    $_backends{plain} //= JMAP::CredentialStore::_Plaintext->new();
}

# Dies unless credentials can be stored as configured: called at startup, so
# a missing key stops the server, not the first signup.
sub check_configured { _active_backend(); return 1 }

# The associated data a credential is bound to: its account and field.
sub context {
    my ($accountid, $field) = @_;
    die "JMAP::CredentialStore: a context needs an account and a field\n"
      unless defined $accountid && length $accountid && defined $field && length $field;
    return "jmap-perl credential\0$accountid\0$field";
}

# Encrypt a credential for storage.  Returns the ciphertext string.
# Passing undef or empty string returns the value unchanged.
sub encrypt {
    my (undef, $plaintext, $context) = @_;
    return $plaintext unless defined $plaintext && length $plaintext;
    die "JMAP::CredentialStore: encrypt needs a context\n" unless defined $context;
    return _active_backend()->encrypt($plaintext, $context);
}

# Decrypt a stored credential.  Auto-detects the backend from the stored prefix,
# so enc1: values can always be decrypted even if the active backend is OpenBao.
sub decrypt {
    my (undef, $value, $context) = @_;
    return $value unless defined $value && length $value;
    if ($value =~ /^enc1:/) {
        die "JMAP::CredentialStore: this credential is in the old enc1 format, no longer read: set the account up again\n";
    }
    if ($value =~ /^(?:enc2|vault):/) {
        die "JMAP::CredentialStore: decrypt needs a context\n" unless defined $context;
        return $value =~ /^enc2:/ ? _aes_backend()->decrypt($value, $context)
                                  : _bao_backend()->decrypt($value, $context);
    }
    return $value;  # plaintext
}

# Deterministic keyed MAC over $data.
#
# For values that must be comparable across accounts but must not reveal their
# input if the database is stolen — the credential fingerprint being the case in
# point: it covers the upstream password, and an unkeyed digest of it would be an
# offline guessing oracle, defeating the point of encrypting credentials at rest.
#
# Equal inputs give equal outputs under a fixed backend, which is all the
# fingerprint needs. When credentials are stored in plaintext anyway there is
# nothing left to protect, so a bare digest is fine.
sub mac {
    my (undef, $data) = @_;
    $data = '' unless defined $data;
    my $backend = _active_backend();
    return $backend->can('mac')
         ? $backend->mac($data)
         : do { require Digest::SHA; Digest::SHA::sha256_hex($data) };
}

# True if the value looks like it has already been encrypted.
sub is_encrypted {
    my (undef, $value) = @_;
    return defined $value && $value =~ /^(?:enc2:|vault:)/;
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

# JMAP_SECRET_KEY is a 256-bit key, as 64 hex characters (openssl rand -hex
# 32).  A passphrase is refused: one SHA-256 of it, as this took before, is
# no defence against guessing it.  The AES key and the MAC key are derived
# from it with HKDF-SHA256, under different labels, never used for both.
sub new {
    my ($class) = @_;
    my $hex = $ENV{JMAP_SECRET_KEY}
        or die "JMAP_SECRET_KEY not set\n";
    die "JMAP_SECRET_KEY must be 64 hex characters, a 256-bit key (run: openssl rand -hex 32)\n"
        unless $hex =~ /^[0-9a-fA-F]{64}$/;
    require Crypt::KeyDerivation;
    my $master = pack 'H*', $hex;
    return bless {
        key    => Crypt::KeyDerivation::hkdf($master, 'jmap-perl', 'SHA256', 32, 'credential encryption v2'),
        mackey => Crypt::KeyDerivation::hkdf($master, 'jmap-perl', 'SHA256', 32, 'credential fingerprint v2'),
    }, $class;
}

# Keyed MAC (HMAC-SHA256), so a stolen database cannot be used to guess the
# MAC'd input offline.
sub mac {
    my ($self, $data) = @_;
    require Digest::SHA;
    return Digest::SHA::hmac_sha256_hex($data, $self->{mackey});
}

sub encrypt {
    my ($self, $plaintext, $context) = @_;
    require Crypt::AuthEnc::GCM;
    my $nonce = '';
    open my $fh, '<:raw', '/dev/urandom' or die "Cannot open /dev/urandom: $!";
    read($fh, $nonce, 12) == 12 or die "Cannot read /dev/urandom\n";
    close $fh;
    my ($ct, $tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES', $self->{key}, $nonce, $context, $plaintext);
    return 'enc2:' . encode_base64($nonce . $ct . $tag, '');
}

sub decrypt {
    my ($self, $stored, $context) = @_;
    require Crypt::AuthEnc::GCM;
    $stored =~ s/^enc2://;
    my $raw = decode_base64($stored);
    die "JMAP::CredentialStore: stored credential is too short\n" if length $raw < 28;
    my $nonce = substr($raw,  0, 12);
    my $tag   = substr($raw, -16);
    my $ct    = substr($raw,  12, length($raw) - 28);
    my $pt    = Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES', $self->{key}, $nonce, $context, $ct, $tag);
    die "JMAP::CredentialStore: AES-GCM authentication failed: wrong key, or a credential that is not this account's\n"
        unless defined $pt;
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

# associated_data (Transit, AEAD keys such as aes256-gcm96) binds the value to
# its account and field, as for AES-GCM above
sub encrypt {
    my ($self, $plaintext, $context) = @_;
    my $b64  = encode_base64($plaintext, '');
    my $resp = $self->_api('POST', "$self->{mount}/encrypt/$self->{key}",
        { plaintext => $b64, associated_data => encode_base64($context, '') });
    return $resp->{data}{ciphertext};  # already looks like "vault:v1:..."
}

# Keyed MAC via the Transit HMAC endpoint.  Deterministic for a given key
# version, which is all a fingerprint comparison needs.  Returns a string like
# "vault:v1:<base64>" — treat it as opaque.
sub mac {
    my ($self, $data) = @_;
    my $resp = $self->_api('POST', "$self->{mount}/hmac/$self->{key}",
        { input => encode_base64($data, ''), algorithm => 'sha2-256' });
    return $resp->{data}{hmac};
}

sub decrypt {
    my ($self, $ciphertext, $context) = @_;
    my $resp = $self->_api('POST', "$self->{mount}/decrypt/$self->{key}",
        { ciphertext => $ciphertext, associated_data => encode_base64($context, '') });
    return decode_base64($resp->{data}{plaintext});
}

1;
