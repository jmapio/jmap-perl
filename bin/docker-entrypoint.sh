#!/bin/bash
set -e

export JMAP_HOME="${JMAP_HOME:-/opt/jmap-perl}"
export JMAP_DATADIR="${JMAP_DATADIR:-/data}"
export JMAP_PORT="${JMAP_PORT:-9000}"
export BASEURL="${BASEURL:-http://localhost:$JMAP_PORT}"

mkdir -p "$JMAP_DATADIR"

# Initialize and migrate accounts DB
perl -MDBI -e "
  my \$dbh = DBI->connect('dbi:SQLite:dbname=$JMAP_DATADIR/accounts.sqlite3');
  \$dbh->do('CREATE TABLE IF NOT EXISTS accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT, needs_backfill INTEGER NOT NULL DEFAULT 1)');
  \$dbh->do('CREATE TABLE IF NOT EXISTS tokens (token TEXT PRIMARY KEY, accountid TEXT NOT NULL, last_used INTEGER, last_ip TEXT)');
  \$dbh->do('UPDATE accounts SET poolid = accountid WHERE poolid IS NULL');
  my (\$v) = \$dbh->selectrow_array('PRAGMA user_version');
  if (\$v < 1) {
    my \$cols = \$dbh->selectall_arrayref('PRAGMA table_info(accounts)');
    my %has = map { \$_->[1] => 1 } \@\$cols;
    unless (\$has{needs_backfill}) {
      \$dbh->do('ALTER TABLE accounts ADD COLUMN needs_backfill INTEGER NOT NULL DEFAULT 1');
      \$dbh->do('UPDATE accounts SET needs_backfill = 1');
    }
    \$dbh->do('PRAGMA user_version = 1');
  }
"

exec perl -I"$JMAP_HOME" "$JMAP_HOME/bin/jmap-proxy.pl"
