#!/usr/bin/perl
#
# JMAP::AccountClaim::claim -- which account a signup lands on, decided by
# the __accounts__ worker in one transaction: a new row, or an existing
# account the caller has proved it owns.  Every signup route (form, OAuth,
# JMAP passthrough, management API) goes through it, then runs setup in the
# worker of the account it names.

use strict;
use warnings;
use lib '.';
use Test::More;
use DBI;
use JMAP::AccountClaim;

sub fresh_db {
  my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
  $dbh->do("CREATE TABLE accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT, needs_backfill INTEGER NOT NULL DEFAULT 1, cred_fingerprint TEXT, nextsend INTEGER)");
  return $dbh;
}

sub row {
  my ($dbh, $aid) = @_;
  return $dbh->selectrow_hashref("SELECT * FROM accounts WHERE accountid = ?", {}, $aid);
}

sub claim_err {
  my ($dbh, $args) = @_;
  my $r = eval { JMAP::AccountClaim::claim($dbh, $args) };
  return $r ? undef : "$@";
}

subtest 'a new email makes a new account' => sub {
  my $dbh = fresh_db();
  my $r = JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'new1', type => 'imap' });
  is_deeply($r, { accountid => 'new1', existed => 0, type => 'imap' }, 'answer');
  my $row = row($dbh, 'new1');
  is($row->{email}, 'a@example.com', 'email');
  is($row->{type}, 'imap', 'type');
  is($row->{poolid}, 'new1', 'its own pool by default');
  is($row->{needs_backfill}, 1, 'backfill pending by default');
};

subtest 'pool and backfill are the caller\'s' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'j@example.com', accountid => 'j1', type => 'jmap',
                                    poolid => 'p1', needs_backfill => 0 });
  my $row = row($dbh, 'j1');
  is($row->{poolid}, 'p1', 'joins the pool');
  is($row->{needs_backfill}, 0, 'no backfill for passthrough');
};

subtest 'an existing email is refused without proof' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'old', type => 'imap' });
  my $err = claim_err($dbh, { email => 'a@example.com', accountid => 'new2', type => 'imap' });
  like($err, qr/already exists/, 'refused');
  ok(!row($dbh, 'new2'), 'no second row');
  $err = claim_err($dbh, { email => 'a@example.com', accountid => 'new3', type => 'imap',
                           exists_error => "custom refusal\n" });
  is($err, "custom refusal\n", 'the caller words the refusal');
};

subtest 'an existing email is bound with proof' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'old', type => 'gmail' });
  my $r = JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'new2', type => 'gmail',
                                            bind => 1, poolid => 'p9' });
  is_deeply($r, { accountid => 'old', existed => 1, type => 'gmail' }, 'lands on the existing account');
  ok(!row($dbh, 'new2'), 'the fresh id is not used');
  is(row($dbh, 'old')->{poolid}, 'p9', 'joins the caller\'s pool');
};

subtest 'binding keeps the pool when none is given' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'old', type => 'imap', poolid => 'p1' });
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'x', type => 'imap', bind => 1 });
  is(row($dbh, 'old')->{poolid}, 'p1', 'pool unchanged');
};

subtest 'an existing account of another type is never bound' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'old', type => 'imap' });
  my $err = claim_err($dbh, { email => 'a@example.com', accountid => 'x', type => 'jmap', bind => 1 });
  like($err, qr/different kind/, 'refused: setup would open it with the wrong class');
  is(row($dbh, 'old')->{type}, 'imap', 'unchanged');
};

subtest 'signup disabled: no new account, binding still works' => sub {
  my $dbh = fresh_db();
  my $err = claim_err($dbh, { email => 'a@example.com', accountid => 'n', type => 'imap', deny_new => 1 });
  like($err, qr/Registration is disabled/, 'new refused');
  ok(!row($dbh, 'n'), 'nothing stored');
  JMAP::AccountClaim::claim($dbh, { email => 'b@example.com', accountid => 'old', type => 'imap' });
  my $r = JMAP::AccountClaim::claim($dbh, { email => 'b@example.com', accountid => 'm', type => 'imap',
                                            bind => 1, deny_new => 1 });
  is($r->{accountid}, 'old', 'a proved existing account still binds');
};

subtest 'an accountid in use under another email is refused' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'acct', type => 'jmap' });
  my $err = claim_err($dbh, { email => 'other@example.com', accountid => 'acct', type => 'jmap', bind => 1 });
  like($err, qr/already in use/, 'refused');
  my $n = $dbh->selectrow_array("SELECT COUNT(*) FROM accounts WHERE accountid = 'acct'");
  is($n, 1, 'still one row for the id');
};

subtest 'a failed claim leaves no transaction open' => sub {
  my $dbh = fresh_db();
  claim_err($dbh, { email => 'a@example.com', accountid => 'n', type => 'imap', deny_new => 1 });
  ok($dbh->{AutoCommit}, 'back in autocommit');
  ok(JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'n', type => 'imap' }),
     'the next claim works');
};

subtest 'arguments are checked' => sub {
  my $dbh = fresh_db();
  like(claim_err($dbh, { accountid => 'n', type => 'imap' }), qr/email/, 'email required');
  like(claim_err($dbh, { email => 'a@example.com', type => 'imap' }), qr/accountid/, 'accountid required');
  like(claim_err($dbh, { email => 'a@example.com', accountid => 'n' }), qr/type/, 'type required');
};

subtest 'set_cred_fingerprint' => sub {
  my $dbh = fresh_db();
  JMAP::AccountClaim::claim($dbh, { email => 'a@example.com', accountid => 'j', type => 'jmap' });
  JMAP::AccountClaim::set_cred_fingerprint($dbh, 'j', 'fp123');
  is(row($dbh, 'j')->{cred_fingerprint}, 'fp123', 'stored');
};

done_testing();
