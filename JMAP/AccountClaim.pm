package JMAP::AccountClaim;

# Which account a signup lands on.  Run by the __accounts__ worker, the only
# writer of accounts.sqlite3, in one transaction: a signup either makes a new
# account under the id it was given, or binds to the existing account for its
# email -- only when the caller has proved it owns that account (an admin, or
# an OAuth provider vouching for the address).  The caller then runs setup in
# the worker of the account this answers, never in the worker that probed the
# credentials, so a re-bound account's own database is the one updated.
#
# Pure apart from the $dbh it is handed; t/account-claim.t covers it.

use strict;
use warnings;

# $args: email, accountid (the id a new account gets), type, and optionally
#   poolid          pool to join (new: default its own id; existing: unchanged)
#   bind            the caller proved ownership: an existing account may be used
#   deny_new        signup is closed: refuse to make a new account
#   needs_backfill  for a new account (default 1)
#   exists_error    the refusal for an existing account without proof
# Answers { accountid, existed, type }; dies with a user-facing message.
sub claim {
  my ($dbh, $args) = @_;
  my $email = $args->{email}     or die "email required\n";
  my $newid = $args->{accountid} or die "accountid required\n";
  my $type  = $args->{type}      or die "type required\n";

  # the accounts worker's handle does not raise: a failed INSERT must not commit
  local $dbh->{RaiseError} = 1;
  $dbh->begin_work;
  my $res = eval {
    my $existing = $dbh->selectrow_hashref(
      "SELECT accountid, type FROM accounts WHERE email = ?", {}, $email);
    if ($existing) {
      die($args->{exists_error} // "An account for $email already exists: log in with its password\n")
        unless $args->{bind};
      # setup opens an account with the class its type names: binding a
      # passthrough login onto an IMAP account (or the reverse) would write
      # one kind of settings into the other kind of database
      die "An account for $email already exists, of a different kind ($existing->{type})\n"
        if ($existing->{type} // '') ne $type;
      $dbh->do("UPDATE accounts SET poolid = ? WHERE accountid = ?", {},
        $args->{poolid}, $existing->{accountid}) if $args->{poolid};
      { accountid => $existing->{accountid}, existed => 1, type => $type };
    }
    else {
      if ($args->{deny_new}) {
        warn "SIGNUP_DISABLED: refusing to create new account for $email (JMAP_DISABLE_SIGNUP is set)\n";
        die "Registration is disabled on this server\n";
      }
      # email is the key, not accountid: without this an admin naming a
      # taken id with a new email made two rows for one account
      my ($taken) = $dbh->selectrow_array(
        "SELECT email FROM accounts WHERE accountid = ?", {}, $newid);
      die "Account id $newid is already in use\n" if $taken;
      $dbh->do("INSERT INTO accounts (email, accountid, type, poolid, needs_backfill) VALUES (?, ?, ?, ?, ?)",
        {}, $email, $newid, $type, $args->{poolid} || $newid, $args->{needs_backfill} // 1);
      { accountid => $newid, existed => 0, type => $type };
    }
  };
  unless ($res) {
    my $err = $@;
    eval { $dbh->rollback };
    die $err;
  }
  $dbh->commit;
  return $res;
}

# The upstream login's fingerprint, once setup has stored those credentials
# (passthrough accounts; see JMAP::JmapDB::cred_fingerprint).
sub set_cred_fingerprint {
  my ($dbh, $accountid, $fp) = @_;
  $dbh->do("UPDATE accounts SET cred_fingerprint = ? WHERE accountid = ?", {}, $fp, $accountid);
}

1;
