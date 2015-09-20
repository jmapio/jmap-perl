#!/usr/bin/perl -w

use DBI;

sub accountsdb {
  my $dbh = DBI->connect("dbi:SQLite:dbname=/home/jmap/data/accounts.sqlite3");
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS accounts (
  email TEXT PRIMARY KEY,
  accountid TEXT,
  type TEXT
);
EOF
  return $dbh;
}

my $dbh = accountsdb();

my $ids = $dbh->selectcol_arrayref("SELECT accountid FROM accounts");

foreach my $id (@$ids) {
  my $file = "/home/jmap/data/$id.sqlite3";
  next unless -f $file;
  my $adbh = DBI->connect("dbi:SQLite:dbname=$file");
  my $tables = $adbh->selectcol_arrayref("SELECT name FROM sqlite_master");
  foreach my $table (@$tables) {
    next if $table eq 'account';
    next if $table eq 'iserver';
    next if $table =~  m/^sqlite_/;
    $adbh->do("DROP TABLE $table");
  }
}

