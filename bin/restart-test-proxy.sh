#!/bin/bash
# Restart the JMAP proxy test servers
# Usage: ./bin/restart-test-proxy.sh [clean] [--jmap]
#   clean: wipe the DB and re-sync
#   --jmap: register test user as a JMAP passthrough account (default: IMAP)

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

CLEAN=0
BACKEND=imap
for arg in "$@"; do
  case "$arg" in
    clean)  CLEAN=1 ;;
    --jmap) BACKEND=jmap ;;
  esac
done

CYRUS_MGMT_URL="${CYRUS_MGMT_URL:-http://localhost:8001}"
CYRUS_CONTAINER="${CYRUS_CONTAINER:-cyrus-test}"

# Kill old servers (including forked children) by port
lsof -ti :"$FRONTEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
pkill -9 -f 'jmap-proxy.pl|apiendpoint.pl|bin/server.pl' 2>/dev/null || true
sleep 2

mkdir -p "$DATADIR"

if [ "$CLEAN" = "1" ]; then
    echo "Cleaning DB and Cyrus user..."
    # Wipe all local state — accounts.sqlite3 will be re-created by the proxy
    rm -f "$DATADIR"/*.sqlite3 "$DATADIR"/*.lock

    # Recreate the Cyrus Docker container for a truly clean state.
    # This wipes all tombstones, accumulated mailbox history, and Cyrus
    # internal state — IMAP DELETE/CREATE leaves tombstone records that
    # corrupt Mailbox/changes responses.
    if docker inspect "$CYRUS_CONTAINER" >/dev/null 2>&1; then
        echo "Recreating Cyrus container ($CYRUS_CONTAINER)..."
        docker stop "$CYRUS_CONTAINER" >/dev/null 2>&1 || true
        docker rm   "$CYRUS_CONTAINER" >/dev/null 2>&1 || true
    fi
    docker run -d --name "$CYRUS_CONTAINER" \
        -p ${CYRUS_IMAP_PORT}:8143 \
        -p 8080:8080 \
        -p 8001:8001 \
        ghcr.io/cyrusimap/cyrus-docker-test-server:latest >/dev/null

    # Wait for Cyrus IMAP to be ready
    echo -n "Waiting for Cyrus..."
    for i in $(seq 1 30); do
        curl -sf http://localhost:8001/ >/dev/null 2>&1 && break
        sleep 1
        echo -n "."
    done
    echo " ready"
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

if [ "$CLEAN" = "1" ]; then
    # Recreate user via Cyrus management API (DELETE+PUT cleanly wipes tombstones).
    # PUT /api/user with inbox-only.json creates a fresh account with just INBOX.
    echo "Creating $CYRUS_USER on Cyrus via management API..."
    curl -sf -X DELETE "${CYRUS_MGMT_URL}/api/${CYRUS_USER}" >/dev/null 2>&1 || true
    curl -sf -X PUT "${CYRUS_MGMT_URL}/api/${CYRUS_USER}" \
        -H 'Content-Type: application/json' \
        -d '{"mailboxes":[{"name":"INBOX","subscribed":true}]}' >/dev/null

    if [ "$BACKEND" = "jmap" ]; then
        # Register as JMAP passthrough account pointing at Cyrus's native JMAP
        RESULT=$(curl -sf -X POST http://localhost:${JMAP_MGMT_PORT}/api/accounts \
            -H 'Content-Type: application/json' \
            -d "{
                \"accountid\":  \"$CYRUS_USER\",
                \"email\":      \"$CYRUS_USER\",
                \"sessionUrl\": \"$CYRUS_URL/jmap\",
                \"username\":   \"$CYRUS_USER\",
                \"password\":   \"$CYRUS_PASS\",
                \"authType\":   \"basic\"
            }")
        echo "Initialized JMAP passthrough: $RESULT"
    else
        # Register as IMAP account (default)
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
        echo "Initialized and synced (IMAP)"
    fi

    # Set a storage quota on the test user so Quota/get returns data
    perl -e '
use Mail::IMAPTalk;
my $imap = Mail::IMAPTalk->new(Server => "localhost", Port => $ENV{CYRUS_IMAP_PORT}, UseSSL => 0, Username => "admin", Password => "admin") or die;
$imap->_imap_cmd("SETQUOTA", 0, "", "user/$ENV{CYRUS_USER}", ["STORAGE", 102400]);
$imap->logout;
' 2>/dev/null && echo "Quota set on $CYRUS_USER" || echo "Warning: could not set quota"
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
  "cyrus_hierarchy_separator"  : ".",
  "cyrus_backend"              : true
}
TESTCONFIG

echo "JMAP proxy running: frontend=:$FRONTEND_PORT mgmt=:$JMAP_MGMT_PORT (backend=$BACKEND)"
echo "  JMAP_DATADIR=$DATADIR"
echo "  JMAP_HOME=$JMAP_HOME"
