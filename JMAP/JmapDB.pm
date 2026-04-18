package JMAP::JmapDB;
use strict;
use warnings;
use DBI;
use HTTP::Tiny;
use JSON::XS qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);

my $datadir = $ENV{JMAP_DATADIR} || $ENV{JMAP_DATA} || '/data';

=head1 NAME

JMAP::JmapDB — JMAP-to-JMAP passthrough account backend

This module provides a thin proxy that forwards JMAP API calls to an upstream
JMAP server, rewriting accountIds between the proxy's internal UUID and the
upstream server's native accountId.

Credentials and upstream discovery info are stored in a per-account SQLite DB
(jserver table).  There is no local caching of mail data — all data lives on
the upstream server.

=cut

sub new {
    my ($class, $accountid) = @_;
    my $dbpath = "$datadir/$accountid.db";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbpath", '', '',
        { RaiseError => 1, AutoCommit => 1 });
    $dbh->do(<<'SQL');
CREATE TABLE IF NOT EXISTS jserver (
    username         TEXT PRIMARY KEY,
    password         TEXT,
    authType         TEXT NOT NULL DEFAULT 'basic',
    sessionUrl       TEXT,
    apiUrl           TEXT,
    uploadUrl        TEXT,
    downloadUrl      TEXT,
    backendAccountId TEXT,
    capabilities     TEXT,
    mtime            INTEGER NOT NULL
)
SQL
    return bless { accountid => $accountid, dbh => $dbh }, $class;
}

sub accountid { $_[0]{accountid} }

# Store/update backend credentials and discovery info.
sub setuser {
    my ($Self, $args) = @_;
    require JMAP::CredentialStore;
    my $dbh = $Self->{dbh};
    $dbh->do(
        "INSERT OR REPLACE INTO jserver
         (username, password, authType, sessionUrl, apiUrl, uploadUrl, downloadUrl,
          backendAccountId, capabilities, mtime)
         VALUES (?,?,?,?,?,?,?,?,?,?)",
        {},
        $args->{username}         // '',
        JMAP::CredentialStore->encrypt($args->{password} // ''),
        $args->{authType}         || 'basic',
        $args->{sessionUrl}       // '',
        $args->{apiUrl}           // '',
        $args->{uploadUrl}        // '',
        $args->{downloadUrl}      // '',
        $args->{backendAccountId} // '',
        encode_json($args->{capabilities} || {}),
        time(),
    );
}

# Return the jserver row as a hashref (password included — caller must strip for display).
sub access_data {
    my ($Self) = @_;
    my $row = $Self->{dbh}->selectrow_hashref("SELECT * FROM jserver LIMIT 1") || {};
    $row->{capabilities} = eval { decode_json($row->{capabilities} || '{}') } || {};
    $row->{type} = 'jmap';
    return $row;
}

# For authType='fastmail_oauth': perform RFC 7591 dynamic registration (synchronous).
my $_fm_client_id;
sub _fm_register_client {
    my $redirect_uri = ($ENV{BASEURL} || 'http://localhost:9000') . '/cb/oauth';
    my $ua  = HTTP::Tiny->new(timeout => 15);
    my $res = $ua->request('POST', 'https://api.fastmail.com/oauth/register', {
        headers => { 'Content-Type' => 'application/json' },
        content => encode_json({
            client_name              => 'jmap-proxy',
            redirect_uris            => [$redirect_uri],
            grant_types              => ['authorization_code', 'refresh_token'],
            response_types           => ['code'],
            token_endpoint_auth_method => 'none',
            scope => 'urn:ietf:params:oauth:scope:mail urn:ietf:params:oauth:scope:contacts '
                   . 'urn:ietf:params:oauth:scope:calendars offline_access',
        }),
    });
    my $data = eval { decode_json($res->{content}) };
    $data->{client_id} or die "Fastmail dynamic registration failed: $res->{content}\n";
    return $data->{client_id};
}

# Exchange a Fastmail OAuth refresh token for a fresh access token (synchronous).
# Caches the result until 60s before expiry.
sub _fm_access_token {
    my ($Self, $refresh_token) = @_;
    if ($Self->{_fm_access_token} && time() < ($Self->{_fm_access_expiry} || 0)) {
        return $Self->{_fm_access_token};
    }
    my $client_id = $ENV{FASTMAIL_CLIENT_ID} || $_fm_client_id || do {
        $_fm_client_id = _fm_register_client();
        $_fm_client_id;
    };
    my $ua  = HTTP::Tiny->new(timeout => 15);
    my $res = $ua->post_form('https://api.fastmail.com/oauth/refresh', {
        client_id     => $client_id,
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
    });
    my $data = eval { decode_json($res->{content}) };
    $data->{access_token} or die "Fastmail token refresh failed: $res->{content}\n";
    $Self->{_fm_access_token}  = $data->{access_token};
    $Self->{_fm_access_expiry} = time() + ($data->{expires_in} || 3600) - 60;
    return $Self->{_fm_access_token};
}

# Build the Authorization header value from stored credentials.
sub _auth_header {
    my ($Self, $server) = @_;
    $server //= $Self->access_data();
    require JMAP::CredentialStore;
    my $password = JMAP::CredentialStore->decrypt($server->{password} // '');
    my $auth_type = $server->{authType} || 'basic';
    if ($auth_type eq 'bearer') {
        return "Bearer $password";
    }
    if ($auth_type eq 'fastmail_oauth') {
        return "Bearer " . $Self->_fm_access_token($password);
    }
    return "Basic " . encode_base64("$server->{username}:$password", '');
}

# Fetch and parse the backend JMAP session object.
# Returns the session hashref on success, or dies with a human-readable error.
sub fetch_session {
    my ($Self, $args) = @_;
    # $args may override stored creds (used during signup/update)
    my $url      = $args->{sessionUrl} || ($Self->access_data())->{sessionUrl};
    my $username = $args->{username}   // ($Self->access_data())->{username} // '';
    my $password = $args->{password}   // ($Self->access_data())->{password} // '';
    my $authType = $args->{authType}   || ($Self->access_data())->{authType} || 'basic';

    my $auth = ($authType eq 'bearer')
        ? "Bearer $password"
        : ($authType eq 'fastmail_oauth')
        ? "Bearer " . $Self->_fm_access_token($password)
        : "Basic " . encode_base64("$username:$password", '');

    my $http = HTTP::Tiny->new(timeout => 30);
    my $resp = $http->get($url, { headers => { Authorization => $auth } });

    die "Cannot reach JMAP session URL ($resp->{status} $resp->{reason}): $url\n"
        unless $resp->{success};

    my $session = eval { decode_json($resp->{content}) };
    die "Invalid JSON from JMAP session URL: $@\n" if $@;

    return ($session, $auth);
}

# Forward a JMAP API request to the upstream server.
# Rewrites proxy accountId ↔ backend accountId in the JSON payload.
sub handle_jmap {
    my ($Self, $request) = @_;

    my $server     = $Self->access_data();
    my $proxy_id   = $Self->{accountid};
    my $backend_id = $server->{backendAccountId}
        or die "No backendAccountId configured for $proxy_id\n";
    my $api_url    = $server->{apiUrl}
        or die "No apiUrl configured for $proxy_id\n";

    # Rewrite proxy UUID → upstream accountId in the serialised request.
    my $req_json = encode_json($request);
    $req_json =~ s/\Q$proxy_id\E/$backend_id/g;

    my $http = HTTP::Tiny->new(timeout => 60);
    my $resp = $http->request('POST', $api_url, {
        headers => {
            'Content-Type'  => 'application/json',
            'Authorization' => $Self->_auth_header($server),
        },
        content => $req_json,
    });

    die "Upstream JMAP request failed: $resp->{status} $resp->{reason}\n"
        unless $resp->{success};

    # Rewrite upstream accountId → proxy UUID in the response.
    my $res_json = $resp->{content};
    $res_json =~ s/\Q$backend_id\E/$proxy_id/g;

    my $response = decode_json($res_json);

    # RFC 8620 §5.3: empty notCreated/notUpdated/notDestroyed MUST be null,
    # not an empty object.  Cyrus returns {} — normalise here.
    for my $triple (@{ $response->{methodResponses} // [] }) {
        my $args = $triple->[1] // {};
        for my $field (qw(notCreated notUpdated notDestroyed)) {
            $args->{$field} = undef
                if ref($args->{$field}) eq 'HASH' && !%{ $args->{$field} };
        }
    }

    return $response;
}

# Proxy a blob upload to the upstream JMAP server.
# Returns the upstream BlobUpload response hashref with accountId rewritten.
sub proxy_upload {
    my ($Self, $type, $filepath) = @_;

    my $server     = $Self->access_data();
    my $upload_url = $server->{uploadUrl}
        or die "No uploadUrl configured for JMAP passthrough account\n";
    my $proxy_id   = $Self->{accountid};
    my $backend_id = $server->{backendAccountId}
        or die "No backendAccountId configured\n";

    # Expand {accountId} template variable in uploadUrl
    (my $url = $upload_url) =~ s/\{accountId\}/$backend_id/g;

    open my $fh, '<:raw', $filepath or die "Cannot open upload file: $!\n";
    local $/;
    my $body = <$fh>;
    close $fh;

    my $http = HTTP::Tiny->new(timeout => 120);
    my $resp = $http->request('POST', $url, {
        headers => {
            'Content-Type'  => $type || 'application/octet-stream',
            'Authorization' => $Self->_auth_header($server),
        },
        content => $body,
    });
    die "Upstream upload failed: $resp->{status} $resp->{reason}\n"
        unless $resp->{success};

    my $result = eval { decode_json($resp->{content}) };
    die "Invalid JSON in upload response: $@\n" if $@;

    # Rewrite upstream accountId → proxy UUID in response
    my $res_json = $resp->{content};
    $res_json =~ s/\Q$backend_id\E/$proxy_id/g;
    return decode_json($res_json);
}

# Proxy a blob download from the upstream JMAP server.
# $blobid is the proxy-side blobId (may contain the upstream accountId embedded).
# Returns ($content_type, $body).
sub proxy_blob {
    my ($Self, $blobid, $name, $type) = @_;

    my $server      = $Self->access_data();
    my $download_tpl = $server->{downloadUrl}
        or die "No downloadUrl configured for JMAP passthrough account\n";
    my $proxy_id    = $Self->{accountid};
    my $backend_id  = $server->{backendAccountId}
        or die "No backendAccountId configured\n";

    # Rewrite proxy UUID → upstream accountId in the blobId (if embedded)
    (my $upstream_blobid = $blobid) =~ s/\Q$proxy_id\E/$backend_id/g;

    # Expand URI template variables (RFC 8620 §2)
    my $url = $download_tpl;
    $url =~ s/\{accountId\}/uri_escape($backend_id)/ge;
    $url =~ s/\{blobId\}/uri_escape($upstream_blobid)/ge;
    $url =~ s/\{type\}/uri_escape($type || 'application\/octet-stream')/ge;
    $url =~ s/\{name\}/uri_escape($name || 'download')/ge;

    my $http = HTTP::Tiny->new(timeout => 120);
    my $resp = $http->get($url, {
        headers => { 'Authorization' => $Self->_auth_header($server) },
    });
    die "Upstream blob fetch failed: $resp->{status} $resp->{reason}\n"
        unless $resp->{success};

    my $content_type = $resp->{headers}{'content-type'} || 'application/octet-stream';
    return ($content_type, $resp->{content});
}

# Clean up the per-account SQLite file.
sub delete {
    my ($Self) = @_;
    my $dbpath = "$datadir/$Self->{accountid}.db";
    $Self->{dbh}->disconnect();
    unlink $dbpath;
}

# Stub — JMAP accounts don't need local state tracking.
sub in_transaction { 0 }
sub reset          {}

1;
