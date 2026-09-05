#!/bin/bash
set -e

export JMAP_HOME="${JMAP_HOME:-/opt/jmap-perl}"
export JMAP_DATADIR="${JMAP_DATADIR:-/data}"
export JMAP_PORT="${JMAP_PORT:-9000}"
export BASEURL="${BASEURL:-http://localhost:$JMAP_PORT}"

mkdir -p "$JMAP_DATADIR"

# Raise the file-descriptor ceiling to the hard limit. The default soft 1024 is
# low for a socket per client plus a socketpair per backend child, and running
# out is not graceful: accept() returns EMFILE and the level-triggered event
# loop then spins at 100% CPU serving nobody.
if [ -n "${JMAP_NOFILE:-}" ]; then
  ulimit -n "$JMAP_NOFILE" 2>/dev/null || echo "warning: could not set ulimit -n to $JMAP_NOFILE" >&2
else
  hard=$(ulimit -Hn 2>/dev/null || echo 1024)
  [ "$hard" = "unlimited" ] && hard=65536
  ulimit -n "$hard" 2>/dev/null || true
fi
echo "file descriptor limit: $(ulimit -n)" >&2

# Initialize and migrate accounts DB
perl -MDBI -e "
  my \$CURRENT = 1;
  my \$dbh = DBI->connect('dbi:SQLite:dbname=$JMAP_DATADIR/accounts.sqlite3');
  my (\$v) = \$dbh->selectrow_array('PRAGMA user_version');
  if (\$v == 0) {
    # Fresh install — create full schema at version 1 (the baseline).
    \$dbh->begin_work;
    \$dbh->do(q{CREATE TABLE accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT, needs_backfill INTEGER NOT NULL DEFAULT 1)});
    \$dbh->do(q{CREATE TABLE tokens (token TEXT PRIMARY KEY, accountid TEXT NOT NULL, last_used INTEGER, last_ip TEXT)});
    \$dbh->do(\"PRAGMA user_version = \$CURRENT\");
    \$dbh->commit;
    exit 0;
  }
  # Incremental migrations. To add version 2:
  #   if (\$v < 2) { \$dbh->begin_work; ... ALTER TABLE ...; \$dbh->do('PRAGMA user_version = 2'); \$dbh->commit; \$v = 2; }
  # Then bump \$CURRENT above.
"

exec perl -I"$JMAP_HOME" "$JMAP_HOME/bin/jmap-proxy.pl"
