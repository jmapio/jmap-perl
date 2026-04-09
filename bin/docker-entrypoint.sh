#!/bin/bash
set -e

export JMAP_HOME="${JMAP_HOME:-/opt/jmap-perl}"
export JMAP_DATADIR="${JMAP_DATADIR:-/data}"
export JMAP_PORT="${JMAP_PORT:-9000}"
export BASEURL="${BASEURL:-http://localhost:$JMAP_PORT}"

mkdir -p "$JMAP_DATADIR"

# Initialize accounts DB if needed
perl -MDBI -e "
  my \$dbh = DBI->connect('dbi:SQLite:dbname=$JMAP_DATADIR/accounts.sqlite3');
  \$dbh->do('CREATE TABLE IF NOT EXISTS accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT)');
  \$dbh->do('CREATE TABLE IF NOT EXISTS tokens (token TEXT PRIMARY KEY, accountid TEXT NOT NULL)');
  eval { \$dbh->do('ALTER TABLE accounts ADD COLUMN poolid TEXT') };
  \$dbh->do('UPDATE accounts SET poolid = accountid WHERE poolid IS NULL');
"

exec perl -I"$JMAP_HOME" "$JMAP_HOME/bin/jmap-proxy.pl"
