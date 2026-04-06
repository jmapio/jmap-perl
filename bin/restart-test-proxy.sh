#!/bin/bash
# Restart the JMAP proxy test servers
# Usage: ./bin/restart-test-proxy.sh [clean]
#   clean: also wipe the DB and re-sync

set -e

DATADIR="${JMAP_DATADIR:-/tmp/jmap-proxy-test}"
BACKEND_PORT="${JMAP_BACKEND_PORT:-5050}"
FRONTEND_PORT=9000
JMAP_HOME="${JMAP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
CYRUS_USER="${CYRUS_USER:-user1}"
CYRUS_PASS="${CYRUS_PASS:-password}"
CYRUS_IMAP_PORT="${CYRUS_IMAP_PORT:-8143}"
CYRUS_URL="${CYRUS_URL:-http://localhost:8080}"

export JMAP_DATADIR="$DATADIR"
export JMAP_HOME
export JMAP_BACKEND_PORT="$BACKEND_PORT"
export BASEURL="http://localhost:$FRONTEND_PORT"

# Kill old servers (including forked children) by port
lsof -ti :"$BACKEND_PORT" -ti :"$FRONTEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
pkill -9 -f 'apiendpoint.pl|bin/server.pl' 2>/dev/null || true
sleep 2

mkdir -p "$DATADIR"

if [ "$1" = "clean" ]; then
    echo "Cleaning DB and Cyrus user..."
    rm -f "$DATADIR/$CYRUS_USER.sqlite3" "$DATADIR/$CYRUS_USER.lock"

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

    # Create accounts DB
    perl -MDBI -e "
      my \$dbh = DBI->connect('dbi:SQLite:dbname=$DATADIR/accounts.sqlite3');
      \$dbh->do('CREATE TABLE IF NOT EXISTS accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT)');
      \$dbh->do('INSERT OR REPLACE INTO accounts (email, accountid, type) VALUES (?, ?, ?)', {}, '$CYRUS_USER', '$CYRUS_USER', 'imap');
    "

    # Initialize and sync
    perl -I"$JMAP_HOME" -Ilib -e "
      use JMAP::ImapDB;
      my \$db = JMAP::ImapDB->new('$CYRUS_USER');
      \$db->setuser({
        username => '$CYRUS_USER', password => '$CYRUS_PASS',
        imapHost => 'localhost', imapPort => $CYRUS_IMAP_PORT, imapSSL => 1,
        smtpHost => 'localhost', smtpPort => 25, smtpSSL => 1,
        caldavURL => '$CYRUS_URL', carddavURL => '$CYRUS_URL',
      });
      \$db->firstsync();
      \$db->sync_imap();
      print \"Initialized and synced\\n\";
    "
fi

# Start backend
perl -I"$JMAP_HOME" -Ilib "$JMAP_HOME/bin/apiendpoint.pl" \
    --port "$BACKEND_PORT" --host 127.0.0.1 2>/tmp/jmap-backend.log &
sleep 2

# Start frontend
perl -I"$JMAP_HOME" -Ilib "$JMAP_HOME/bin/server.pl" 2>/tmp/jmap-frontend.log &
sleep 2

echo "JMAP proxy running: frontend=:$FRONTEND_PORT backend=:$BACKEND_PORT"
echo "  JMAP_DATADIR=$DATADIR"
echo "  JMAP_HOME=$JMAP_HOME"
