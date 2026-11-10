#!/bin/bash
# Restart the JMAP proxy test servers
# Usage: ./bin/restart-test-proxy.sh [clean] [--jmap]
#   clean: wipe the DB and re-sync
#   --jmap: register test user as a JMAP passthrough account (default: IMAP)
# Env: CYRUS_IMAGE overrides the Cyrus test-server image used by `clean`
#   (e.g. a locally built cyrus-test-server:<branch> to test a Cyrus fix).

set -e

DATADIR="${JMAP_DATADIR:-/tmp/jmap-proxy-test}"
FRONTEND_PORT=9000
JMAP_HOME="${JMAP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
CYRUS_USER="${CYRUS_USER:-user1}"
CYRUS_PASS="${CYRUS_PASS:-password}"
# the management API token (it is required: see JMAP_MGMT_TOKEN in SETUP.md)
JMAP_MGMT_TOKEN="${JMAP_MGMT_TOKEN:-test-mgmt-token-for-the-local-stack}"
# credentials are encrypted (JMAP::CredentialStore): a fixed key, for this stack only
JMAP_SECRET_KEY="${JMAP_SECRET_KEY:-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"
# The test image puts its users in example.com (virtdomains: userid), and its
# Postfix takes submissions with AUTH PLAIN on 8587 (no TLS needed).
CYRUS_DOMAIN="${CYRUS_DOMAIN:-example.com}"
CYRUS_SMTP_PORT="${CYRUS_SMTP_PORT:-8587}"
CYRUS_IMAP_PORT="${CYRUS_IMAP_PORT:-8143}"
CYRUS_URL="${CYRUS_URL:-http://localhost:8080}"

export JMAP_DATADIR="$DATADIR"
export JMAP_HOME
export BASEURL="http://localhost:$FRONTEND_PORT"
# The test server's defaultacl gives "admin" an ACE on every mailbox, which
# Cyrus lists in DAV:acl but will not take back in an ACL request.
export JMAP_FILES_DROPPABLE_PRINCIPALS="${JMAP_FILES_DROPPABLE_PRINCIPALS:-admin}"
# A small in-memory cap on one file's content (default 256 MiB), so the
# live tests can show a direct PUT, a download and a copy refusing one.
export JMAP_FILES_MAX_BYTES="${JMAP_FILES_MAX_BYTES:-1048576}"

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
pkill -9 -f 'jmap-proxy.pl' 2>/dev/null || true
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
    BASE_IMAGE="${CYRUS_IMAGE:-ghcr.io/cyrusimap/cyrus-docker-test-server:latest}"
    # Cyrus regenerates /etc/imapd.conf from the image's template at every
    # boot, and restarting the container breaks its auth, so the settings the
    # proxy's tests need are baked into a derived image:
    # - webdav in httpmodules, for FileNode;
    # - munge8bit: no. Cyrus's default rewrites every 8-bit header byte to 'X'
    #   on delivery and APPEND, so an EAI message (RFC 6532, which RFC 8621
    #   S4.8 says the server MUST support) could never be stored intact.
    # The tag carries a hash of this recipe, so changing it rebuilds the image.
    DERIVED_RECIPE='RUN sed -i "s/^httpmodules: .*/httpmodules: caldav carddav jmap webdav/" /srv/testserver/imapd.conf && printf "munge8bit: no\\n" >> /srv/testserver/imapd.conf'
    RECIPE_TAG=$(printf '%s' "$DERIVED_RECIPE" | shasum | cut -c1-8)
    case "${BASE_IMAGE##*/}" in
        *:*) WEBDAV_IMAGE="${BASE_IMAGE%:*}:${BASE_IMAGE##*:}-proxytest-$RECIPE_TAG" ;;
        *)   WEBDAV_IMAGE="${BASE_IMAGE}-proxytest-$RECIPE_TAG" ;;
    esac
    if ! docker image inspect "$WEBDAV_IMAGE" >/dev/null 2>&1; then
        printf 'FROM %s\n%s\n' "$BASE_IMAGE" "$DERIVED_RECIPE" \
            | docker build -q -t "$WEBDAV_IMAGE" - >/dev/null
    fi
    docker run -d --name "$CYRUS_CONTAINER" \
        -p ${CYRUS_IMAP_PORT}:8143 \
        -p 8080:8080 \
        -p 8001:8001 \
        -p ${CYRUS_SMTP_PORT}:8587 \
        -p 8025:8025 \
        "$WEBDAV_IMAGE" >/dev/null

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

# the test Cyrus, Postfix and WebDAV are on localhost: allow private addresses
JMAP_ALLOW_PRIVATE_BACKENDS=1 JMAP_MGMT_TOKEN="$JMAP_MGMT_TOKEN" JMAP_SECRET_KEY="$JMAP_SECRET_KEY" perl -I"$JMAP_HOME" -Ilib "$JMAP_HOME/bin/jmap-proxy.pl" 2>/tmp/jmap-proxy.log &

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
        -d '{"mailboxes":[{"name":"INBOX","subscribed":true}],"quota_kb":102400}' >/dev/null

    if [ "$BACKEND" = "jmap" ]; then
        # Register as JMAP passthrough account pointing at Cyrus's native JMAP
        RESULT=$(curl -sf -X POST http://localhost:${JMAP_MGMT_PORT}/api/accounts \
            -H "Authorization: Bearer $JMAP_MGMT_TOKEN" \
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
            -H "Authorization: Bearer $JMAP_MGMT_TOKEN" \
            -H 'Content-Type: application/json' \
            -d "{
                \"accountid\": \"$CYRUS_USER\",
                \"email\":     \"$CYRUS_USER@$CYRUS_DOMAIN\",
                \"type\":      \"imap\",
                \"username\":  \"$CYRUS_USER\",
                \"password\":  \"$CYRUS_PASS\",
                \"imapHost\":  \"localhost\",
                \"imapPort\":  $CYRUS_IMAP_PORT,
                \"imapSSL\":   1,
                \"smtpHost\":  \"localhost\",
                \"smtpPort\":  $CYRUS_SMTP_PORT,
                \"smtpSSL\":   1,
                \"caldavURL\": \"$CYRUS_URL\",
                \"carddavURL\":\"$CYRUS_URL\",
                \"webdavURL\": \"$CYRUS_URL/dav/drive/user/$CYRUS_USER/\"
            }" >/dev/null
        echo "Initialized and synced (IMAP)"
    fi

fi

# Write test config for JMAP-TestSuite (proxy mode)
cat > "$DATADIR/test-config.json" <<TESTCONFIG
{
  "adapter"                    : "JMAPProxy",
  "accountIds"                 : [ "$CYRUS_USER" ],
  "base_uri"                   : "http://localhost:$FRONTEND_PORT/",
  "mgmt_uri"                   : "http://localhost:$JMAP_MGMT_PORT/",
  "mgmt_token"                 : "$JMAP_MGMT_TOKEN",
  "cyrus_host"                 : "localhost",
  "cyrus_port"                 : $CYRUS_IMAP_PORT,
  "cyrus_http_url"             : "$CYRUS_URL",
  "cyrus_password"             : "$CYRUS_PASS",
  "cyrus_admin_user"           : "admin",
  "cyrus_admin_pass"           : "admin",
  "cyrus_hierarchy_separator"  : ".",
$( [ "$BACKEND" = "jmap" ] || printf '  "mail_domain"                : "%s",\n  "smtp_host"                  : "localhost",\n  "smtp_port"                  : %s,\n' "$CYRUS_DOMAIN" "$CYRUS_SMTP_PORT" )
  "cyrus_backend"              : $( [ "$BACKEND" = "jmap" ] && echo true || echo false ),
  "passthrough"                : $( [ "$BACKEND" = "jmap" ] && echo true || echo false )
}
TESTCONFIG

# Write test config for direct Cyrus access (bypassing the proxy)
cat > "$DATADIR/cyrus-direct-config.json" <<DIRECTCONFIG
{
  "adapter"          : "CyrusDirect",
  "accountIds"       : [ "$CYRUS_USER" ],
  "base_uri"         : "$CYRUS_URL/",
  "mgmt_uri"         : "http://localhost:8001/",
  "cyrus_host"       : "localhost",
  "cyrus_port"       : $CYRUS_IMAP_PORT,
  "cyrus_password"   : "$CYRUS_PASS",
  "cyrus_admin_user" : "admin",
  "cyrus_admin_pass" : "admin"
}
DIRECTCONFIG

echo "JMAP proxy running: frontend=:$FRONTEND_PORT mgmt=:$JMAP_MGMT_PORT (backend=$BACKEND)"
echo "  JMAP_DATADIR=$DATADIR"
echo "  JMAP_HOME=$JMAP_HOME"
