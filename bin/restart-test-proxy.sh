#!/bin/bash
# Restart the JMAP proxy test servers
# Usage: ./bin/restart-test-proxy.sh [clean]
#   clean: also wipe the DB and re-sync

set -e

DATADIR="${JMAP_DATADIR:-/tmp/jmap-proxy-test}"
FRONTEND_PORT=9000
JMAP_HOME="${JMAP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
CYRUS_USER="${CYRUS_USER:-user1}"
CYRUS_PASS="${CYRUS_PASS:-password}"
CYRUS_IMAP_PORT="${CYRUS_IMAP_PORT:-8143}"
CYRUS_URL="${CYRUS_URL:-http://localhost:8080}"

export JMAP_DATADIR="$DATADIR"
export JMAP_HOME
export BASEURL="http://localhost:$FRONTEND_PORT"

# Kill old servers (including forked children) by port
lsof -ti :"$FRONTEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
pkill -9 -f 'jmap-proxy.pl|apiendpoint.pl|bin/server.pl' 2>/dev/null || true
sleep 2

mkdir -p "$DATADIR"

if [ "$1" = "clean" ]; then
    echo "Cleaning DB and Cyrus user..."
    # Wipe all local state — accounts.sqlite3 will be re-created by the proxy
    rm -f "$DATADIR"/*.sqlite3 "$DATADIR"/*.lock

    # Nuke and recreate user on Cyrus
    perl -e '
      use IO::Socket::INET;
      my $s = IO::Socket::INET->new(PeerAddr => "localhost", PeerPort => '$CYRUS_IMAP_PORT', Timeout => 3) or die "cannot connect";
      <$s>;
      print $s "A LOGIN admin admin\r\n"; <$s>;
      print $s "B SETACL user.'$CYRUS_USER' admin lrswipkxtecdan\r\n"; <$s>;
      print $s "C DELETE user.'$CYRUS_USER'\r\n"; <$s>;
      print $s "D CREATE user.'$CYRUS_USER'\r\n"; <$s>;
      print $s "E SETACL user.'$CYRUS_USER' '$CYRUS_USER' lrswipkxtecdan\r\n"; <$s>;
      print $s "F LOGOUT\r\n";
      close $s;
    ' 2>/dev/null
fi

# Start single-process proxy (creates accounts.sqlite3 with correct schema on first run)
JMAP_MGMT_PORT="${JMAP_MGMT_PORT:-8081}"
export JMAP_MGMT_PORT
export JMAP_PORT="$FRONTEND_PORT"

perl -I"$JMAP_HOME" -Ilib "$JMAP_HOME/bin/jmap-proxy.pl" 2>/tmp/jmap-proxy.log &

# Wait for the management port to be ready
for i in $(seq 1 30); do
    curl -sf http://localhost:${JMAP_MGMT_PORT}/healthz >/dev/null 2>&1 && break
    sleep 1
done

if [ "$1" = "clean" ]; then
    # Register the test user via the management API (correct schema, firstsync included)
    curl -sf -X POST http://localhost:${JMAP_MGMT_PORT}/api/accounts \
        -H 'Content-Type: application/json' \
        -d "{
            \"accountid\": \"$CYRUS_USER\",
            \"email\":     \"$CYRUS_USER\",
            \"type\":      \"imap\",
            \"username\":  \"$CYRUS_USER\",
            \"password\":  \"$CYRUS_PASS\",
            \"imapHost\":  \"localhost\",
            \"imapPort\":  $CYRUS_IMAP_PORT,
            \"imapSSL\":   1,
            \"smtpHost\":  \"localhost\",
            \"smtpPort\":  25,
            \"smtpSSL\":   1,
            \"caldavURL\": \"$CYRUS_URL\",
            \"carddavURL\":\"$CYRUS_URL\"
        }" >/dev/null
    echo "Initialized and synced"
fi

# Write test config for JMAP-TestSuite
cat > "$DATADIR/test-config.json" <<TESTCONFIG
{
  "adapter"                    : "JMAPProxy",
  "accountIds"                 : [ "$CYRUS_USER" ],
  "base_uri"                   : "http://localhost:$FRONTEND_PORT/",
  "mgmt_uri"                   : "http://localhost:$JMAP_MGMT_PORT/",
  "cyrus_host"                 : "localhost",
  "cyrus_port"                 : $CYRUS_IMAP_PORT,
  "cyrus_http_url"             : "$CYRUS_URL",
  "cyrus_password"             : "$CYRUS_PASS",
  "cyrus_admin_user"           : "admin",
  "cyrus_admin_pass"           : "admin",
  "cyrus_hierarchy_separator"  : "."
}
TESTCONFIG

echo "JMAP proxy running: frontend=:$FRONTEND_PORT mgmt=:$JMAP_MGMT_PORT"
echo "  JMAP_DATADIR=$DATADIR"
echo "  JMAP_HOME=$JMAP_HOME"
