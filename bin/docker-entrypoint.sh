#!/bin/bash
set -e

export JMAP_HOME="${JMAP_HOME:-/opt/jmap-perl}"
export JMAP_DATADIR="${JMAP_DATADIR:-/data}"
export JMAP_PORT="${JMAP_PORT:-9000}"
export BASEURL="${BASEURL:-http://localhost:$JMAP_PORT}"

mkdir -p "$JMAP_DATADIR"

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
