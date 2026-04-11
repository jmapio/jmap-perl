package JMAP::JmapDB;
use strict;
use warnings;
use DBI;
use HTTP::Tiny;
use JSON::XS qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);

my $datadir = $ENV{JMAP_DATA} || '/data';

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
    my $dbh = $Self->{dbh};
    $dbh->do(
        "INSERT OR REPLACE INTO jserver
         (username, password, authType, sessionUrl, apiUrl, backendAccountId, capabilities, mtime)
         VALUES (?,?,?,?,?,?,?,?)",
        {},
        $args->{username}         // '',
        $args->{password}         // '',
        $args->{authType}         || 'basic',
        $args->{sessionUrl}       // '',
        $args->{apiUrl}           // '',
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

# Build the Authorization header value from stored credentials.
sub _auth_header {
    my ($Self, $server) = @_;
    $server //= $Self->access_data();
    if (($server->{authType} || 'basic') eq 'bearer') {
        return "Bearer $server->{password}";
    }
    return "Basic " . encode_base64("$server->{username}:$server->{password}", '');
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

    return decode_json($res_json);
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
