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

# Start single-process proxy
JMAP_MGMT_PORT="${JMAP_MGMT_PORT:-8081}"
export JMAP_MGMT_PORT
export JMAP_PORT="$FRONTEND_PORT"

perl -I"$JMAP_HOME" -Ilib "$JMAP_HOME/bin/jmap-proxy.pl" 2>/tmp/jmap-proxy.log &
sleep 3

echo "JMAP proxy running: frontend=:$FRONTEND_PORT mgmt=:$JMAP_MGMT_PORT"
echo "  JMAP_DATADIR=$DATADIR"
echo "  JMAP_HOME=$JMAP_HOME"
