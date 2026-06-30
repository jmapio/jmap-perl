# JMAP Passthrough Finishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make JMAP-to-JMAP passthrough accounts fully functional against the local Cyrus server, verified by the JMAP-TestSuite in `--jmap` mode.

**Architecture:** `JMAP::JmapDB` forwards JMAP requests to an upstream server. This plan fixes the integration edges around that engine: unify the per-account SQLite filename, make credential lookups and `/session` capability assembly type-aware, rewrite accountIds structurally (not by string substitution), and teach the test adapter to provision passthrough accounts.

**Tech Stack:** Perl 5, AnyEvent (parent event loop), DBI/SQLite, HTTP::Tiny, JSON::XS. Tests: `Test::More` + `prove`. Integration: Cyrus Docker test server, JMAP-TestSuite.

## Global Constraints

- **Never block the parent.** All upstream HTTP and per-account DB work happens in a child process; the parent only routes and assembles via `send_backend_request` callbacks.
- **Per-account DB file is `$datadir/$accountid.sqlite3`** for every account type after Task 1.
- **Account type** comes from the `type` column in `accounts.sqlite3` (`jmap` for passthrough, `imap`/`gmail`/`fastmail` otherwise).
- **Credentials are encrypted** via `JMAP::CredentialStore`; always `decrypt` stored values before comparing.
- **The proxy serves its own URLs** (`$BASEURL/jmap`, `$BASEURL/upload/{accountId}`, `$BASEURL/raw/...`, `$BASEURL/eventsource...`); upstream URLs are never exposed to the client.
- **Modules read `$datadir` at load time** (`my $datadir = $ENV{JMAP_DATADIR} ...`), so tests that load `JMAP::JmapDB` must set `$ENV{JMAP_DATADIR}` in a `BEGIN` block before `use`.
- Commit after each task. Work on the `jmap-passthrough` branch (already created).

---

### Task 1: Unify the JmapDB per-account DB filename to `.sqlite3`

**Files:**
- Modify: `JMAP/JmapDB.pm:28` (constructor dbpath) and the `delete` sub (dbpath, ~line 297)
- Test: `t/jmapdb-file.t` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `JMAP::JmapDB->new($accountid)` creates `$JMAP_DATADIR/$accountid.sqlite3`; `$db->delete` removes it.

- [ ] **Step 1: Write the failing test**

Create `t/jmapdb-file.t`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

my $dir;
BEGIN { $dir = tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

my $db = JMAP::JmapDB->new('acctX');
ok(-f "$dir/acctX.sqlite3", 'creates per-account .sqlite3 file');
ok(!-f "$dir/acctX.db",     'does not create a .db file');

$db->delete;
ok(!-f "$dir/acctX.sqlite3", 'delete removes the .sqlite3 file');

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl -Ilib t/jmapdb-file.t`
Expected: FAIL — "creates per-account .sqlite3 file" is not ok (the file is created as `acctX.db`).

- [ ] **Step 3: Change the constructor path**

In `JMAP/JmapDB.pm`, the `new` sub, change:

```perl
    my $dbpath = "$datadir/$accountid.db";
```
to:
```perl
    my $dbpath = "$datadir/$accountid.sqlite3";
```

- [ ] **Step 4: Change the delete path**

In `JMAP/JmapDB.pm`, the `delete` sub, change:

```perl
    my $dbpath = "$datadir/$Self->{accountid}.db";
```
to:
```perl
    my $dbpath = "$datadir/$Self->{accountid}.sqlite3";
```

- [ ] **Step 5: Run test to verify it passes**

Run: `perl -Ilib t/jmapdb-file.t`
Expected: PASS — all three assertions ok.

- [ ] **Step 6: Commit**

```bash
git add JMAP/JmapDB.pm t/jmapdb-file.t
git commit -m "JmapDB: use .sqlite3 per-account file to match ImapDB/DB"
```

---

### Task 2: Structured accountId rewriting in `handle_jmap`

Replace the blind `s/proxy_id/backend_id/g` string substitution (which corrupts email addresses like `user1@example.com` when the proxy id is `user1`) with structured rewriting of only the accountId fields in each method call/response.

**Files:**
- Modify: `JMAP/JmapDB.pm` — `handle_jmap` sub (the two `s///g` lines) + add a package-level helper `_rewrite_method_ids`
- Test: `t/jmapdb-rewrite.t` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `JMAP::JmapDB::_rewrite_method_ids($calls_arrayref, $from, $to)` — mutates each `[name, args, tag]` triple in place, rewriting `$args->{accountId|fromAccountId|toAccountId}` from `$from` to `$to` when they exactly equal `$from`. Returns the same arrayref. Works for both `methodCalls` (request) and `methodResponses` (response) since both are `[name, args, tag]` triples.

- [ ] **Step 1: Write the failing test**

Create `t/jmapdb-rewrite.t`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

my $dir;
BEGIN { require File::Temp; $dir = File::Temp::tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

my $calls = [
  ['Email/get', { accountId => 'user1', ids => ['m1'] }, '0'],
  ['Email/set', {
      accountId => 'user1',
      create    => { k => { from => [{ email => 'user1@example.com', name => 'user1' }] } },
  }, '1'],
  ['Email/copy', { fromAccountId => 'user1', toAccountId => 'user1', create => {} }, '2'],
];

JMAP::JmapDB::_rewrite_method_ids($calls, 'user1', 'backend99');

is($calls->[0][1]{accountId}, 'backend99', 'Email/get accountId rewritten');
is($calls->[1][1]{accountId}, 'backend99', 'Email/set accountId rewritten');
is($calls->[1][1]{create}{k}{from}[0]{email}, 'user1@example.com',
   'email address in body is NOT corrupted');
is($calls->[1][1]{create}{k}{from}[0]{name}, 'user1',
   'name field in body is NOT corrupted');
is($calls->[2][1]{fromAccountId}, 'backend99', 'fromAccountId rewritten');
is($calls->[2][1]{toAccountId},   'backend99', 'toAccountId rewritten');

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl -Ilib t/jmapdb-rewrite.t`
Expected: FAIL — "Undefined subroutine &JMAP::JmapDB::_rewrite_method_ids".

- [ ] **Step 3: Add the helper sub**

In `JMAP/JmapDB.pm`, add near the top of the package (after the `use` lines):

```perl
my @ID_KEYS = qw(accountId fromAccountId toAccountId);

# Rewrite only the accountId-style fields in each [name, args, tag] triple,
# leaving message bodies/addresses untouched. Used for both the request
# (methodCalls) and the response (methodResponses).
sub _rewrite_method_ids {
    my ($triples, $from, $to) = @_;
    for my $triple (@{ $triples || [] }) {
        my $args = $triple->[1];
        next unless ref $args eq 'HASH';
        for my $k (@ID_KEYS) {
            $args->{$k} = $to
                if defined $args->{$k} && !ref $args->{$k} && $args->{$k} eq $from;
        }
    }
    return $triples;
}
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `perl -Ilib t/jmapdb-rewrite.t`
Expected: PASS — all six assertions ok.

- [ ] **Step 5: Replace the blind substitution in `handle_jmap`**

In `JMAP/JmapDB.pm`, the `handle_jmap` sub currently reads:

```perl
    # Rewrite proxy UUID → upstream accountId in the serialised request.
    my $req_json = encode_json($request);
    $req_json =~ s/\Q$proxy_id\E/$backend_id/g;
```

Replace those three lines with:

```perl
    # Rewrite proxy accountId → upstream accountId in the method calls only
    # (string substitution would corrupt message bodies that contain the id).
    _rewrite_method_ids($request->{methodCalls}, $proxy_id, $backend_id);
    my $req_json = encode_json($request);
```

Then, later in the same sub:

```perl
    # Rewrite upstream accountId → proxy UUID in the response.
    my $res_json = $resp->{content};
    $res_json =~ s/\Q$backend_id\E/$proxy_id/g;

    my $response = decode_json($res_json);
```

Replace with:

```perl
    my $response = decode_json($resp->{content});
    # Rewrite upstream accountId → proxy accountId in the method responses only.
    _rewrite_method_ids($response->{methodResponses}, $backend_id, $proxy_id);
```

Leave the `notCreated`/`notUpdated`/`notDestroyed` normalisation block that follows unchanged.

- [ ] **Step 6: Run the helper test again (regression)**

Run: `perl -Ilib t/jmapdb-rewrite.t`
Expected: PASS (unchanged — confirms the helper still behaves after the `handle_jmap` edit).

- [ ] **Step 7: Commit**

```bash
git add JMAP/JmapDB.pm t/jmapdb-rewrite.t
git commit -m "JmapDB: rewrite accountIds structurally, not by string substitution"
```

> **Note on `proxy_blob`/`proxy_upload`:** their blobId rewriting still uses string substitution. BlobIds are opaque tokens unlikely to contain free text, so this is left as-is. If Task 7 surfaces blob-id corruption, apply the same field-targeted approach there.

---

### Task 3: Type-aware credential reads in the `__accounts__` child

Make `auth`, `verify_credentials`, and `_account_details_child` read the `jserver` table for `type='jmap'` accounts.

**Files:**
- Modify: `bin/jmap-proxy.pl` — `auth` handler (~lines 961-990), `verify_credentials` handler (~lines 992-1011), `_account_details_child` sub (~lines 1060-1083)

**Interfaces:**
- Consumes: `JMAP::CredentialStore->decrypt`.
- Produces: For a `type='jmap'` account with `authType='basic'`, Basic auth against the proxy succeeds when the supplied password matches the decrypted `jserver.password`. For `authType` of `bearer`/`fastmail_oauth`, both `auth` and `verify_credentials` return `undef` (token/cookie auth only). `_account_details_child` returns `{ configured => 1, username => ..., type => 'jmap' }` for a configured passthrough account.

- [ ] **Step 1: Write the failing integration check (manual harness)**

This handler is inline in the worker script, so it is verified against a running passthrough proxy rather than a unit test. First bring up the stack and confirm the *current* failure:

```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh --jmap clean
curl -s -o /dev/null -w '%{http_code}\n' -u user1:password http://localhost:9000/session
```
Expected (before the fix): `500` or `401` — auth reads the `iserver` table, which a passthrough account does not have.

- [ ] **Step 2: Make the `auth` handler type-aware**

In `bin/jmap-proxy.pl`, the `auth` handler currently reads:

```perl
        # Check password against per-account DB (credentials in iserver table)
        my $aid = $row->{accountid};
        my $dbfile = "$datadir/$aid.sqlite3";
        return ['auth', undef] unless -f $dbfile;
        my $udb = DBI->connect("dbi:SQLite:dbname=$dbfile");
        my $stored = $udb->selectrow_hashref(
          "SELECT password FROM iserver WHERE username = ?", {}, $email);
        return ['auth', undef] unless $stored && $stored->{password} eq $password;
```

Replace with (note: also fetch `type`, and decrypt for the jmap path):

```perl
        # Check password against per-account DB
        my $aid  = $row->{accountid};
        my $type = $dbh->selectrow_array(
          "SELECT type FROM accounts WHERE accountid = ?", {}, $aid) // '';
        my $dbfile = "$datadir/$aid.sqlite3";
        return ['auth', undef] unless -f $dbfile;
        my $udb = DBI->connect("dbi:SQLite:dbname=$dbfile");

        if ($type eq 'jmap') {
          my $stored = $udb->selectrow_hashref(
            "SELECT password, authType FROM jserver WHERE username = ?", {}, $email);
          return ['auth', undef] unless $stored;
          # Only basic-auth passthrough accounts have a comparable password.
          return ['auth', undef] unless ($stored->{authType} || 'basic') eq 'basic';
          require JMAP::CredentialStore;
          my $actual = JMAP::CredentialStore->decrypt($stored->{password} // '');
          return ['auth', undef] unless $actual eq $password;
        }
        else {
          my $stored = $udb->selectrow_hashref(
            "SELECT password FROM iserver WHERE username = ?", {}, $email);
          return ['auth', undef] unless $stored && $stored->{password} eq $password;
        }
```

- [ ] **Step 3: Make the `verify_credentials` handler type-aware**

In `bin/jmap-proxy.pl`, the `verify_credentials` handler currently reads (from the type check through the password comparison):

```perl
        # OAuth accounts have no stored password to compare against
        return ['verify_credentials', undef]
          if ($row->{type} // '') eq 'gmail' || ($row->{type} // '') eq 'fastmail';
        my $dbfile = "$datadir/$aid.sqlite3";
        return ['verify_credentials', undef] unless -f $dbfile;
        my $udb = DBI->connect("dbi:SQLite:dbname=$dbfile");
        my $stored = $udb->selectrow_hashref(
          "SELECT password FROM iserver WHERE username = ?", {}, $email);
        return ['verify_credentials', undef] unless $stored;
        require JMAP::CredentialStore;
        my $actual = JMAP::CredentialStore->decrypt($stored->{password});
        return ['verify_credentials', undef] unless $actual eq $password;
        return ['verify_credentials', { accountid => $aid }];
```

Replace with:

```perl
        # OAuth accounts have no stored password to compare against
        my $type = $row->{type} // '';
        return ['verify_credentials', undef]
          if $type eq 'gmail' || $type eq 'fastmail';
        my $dbfile = "$datadir/$aid.sqlite3";
        return ['verify_credentials', undef] unless -f $dbfile;
        my $udb = DBI->connect("dbi:SQLite:dbname=$dbfile");
        require JMAP::CredentialStore;

        if ($type eq 'jmap') {
          my $stored = $udb->selectrow_hashref(
            "SELECT password, authType FROM jserver WHERE username = ?", {}, $email);
          return ['verify_credentials', undef] unless $stored;
          return ['verify_credentials', undef]
            unless ($stored->{authType} || 'basic') eq 'basic';
          my $actual = JMAP::CredentialStore->decrypt($stored->{password} // '');
          return ['verify_credentials', undef] unless $actual eq $password;
          return ['verify_credentials', { accountid => $aid }];
        }

        my $stored = $udb->selectrow_hashref(
          "SELECT password FROM iserver WHERE username = ?", {}, $email);
        return ['verify_credentials', undef] unless $stored;
        my $actual = JMAP::CredentialStore->decrypt($stored->{password});
        return ['verify_credentials', undef] unless $actual eq $password;
        return ['verify_credentials', { accountid => $aid }];
```

- [ ] **Step 4: Make `_account_details_child` type-aware**

In `bin/jmap-proxy.pl`, `_account_details_child` currently opens the file and reads `iserver` unconditionally. Replace the body after the `$udb` connect with a type branch. The full sub becomes:

```perl
sub _account_details_child {
  my ($accountid) = @_;
  my $dbfile = "$datadir/$accountid.sqlite3";
  return {} unless -f $dbfile;
  my $udb = eval { DBI->connect("dbi:SQLite:dbname=$dbfile") };
  return {} unless $udb;

  # Passthrough accounts keep credentials in the jserver table.
  my $has_jserver = eval {
    $udb->selectrow_array(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='jserver'");
  };
  if ($has_jserver) {
    my $j = eval { $udb->selectrow_hashref("SELECT * FROM jserver LIMIT 1") } || {};
    return {
      configured => (defined $j->{username} && length $j->{username} ? 1 : 0),
      username   => $j->{username},
      type       => 'jmap',
    };
  }

  my $iserver = eval { $udb->selectrow_hashref("SELECT * FROM iserver LIMIT 1") } || {};
  my ($folders) = eval { $udb->selectrow_array("SELECT COUNT(*) FROM ifolders") } // 0;
  my ($messages) = eval { $udb->selectrow_array("SELECT COUNT(*) FROM jmessages WHERE active = 1") } // 0;
  return {
    configured => (defined $iserver->{username} ? 1 : 0),
    username   => $iserver->{username},
    imapHost   => $iserver->{imapHost},
    imapPort   => $iserver->{imapPort},
    caldavURL  => $iserver->{caldavURL},
    carddavURL => $iserver->{carddavURL},
    folders    => $folders,
    messages   => $messages,
  };
}
```

- [ ] **Step 5: Restart and verify Basic auth now succeeds**

```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh --jmap clean
curl -s -o /dev/null -w '%{http_code}\n' -u user1:password http://localhost:9000/session
```
Expected (after the fix): `200`.

- [ ] **Step 6: Commit**

```bash
git add bin/jmap-proxy.pl
git commit -m "proxy: type-aware credential lookups for jmap passthrough accounts"
```

---

### Task 4: Add the `session_caps` worker command

A per-account child command that fetches the upstream session and returns the rewritten capability slice for `/session` assembly.

**Files:**
- Modify: `bin/jmap-proxy.pl` — per-account worker command loop (add a branch alongside `get_settings`, ~line 733)

**Interfaces:**
- Consumes: `JMAP::JmapDB::fetch_session`, `JMAP::JmapDB::access_data`.
- Produces: worker command `session_caps` returns `['session_caps', { accountCapabilities, capabilities, name, isReadOnly, isPersonal, primaryAccounts }]`, all with the upstream backend accountId rewritten to the proxy accountId. Consumed by `do_session` in Task 5.

- [ ] **Step 1: Add the `session_caps` command branch**

In `bin/jmap-proxy.pl`, immediately before the `if ($cmd eq 'get_settings') {` line in the per-account worker loop, insert:

```perl
      if ($cmd eq 'session_caps') {
        # Passthrough only: fetch the upstream session and return the capability
        # slice for this account, rewritten to the proxy accountId.
        die "session_caps only valid for passthrough accounts\n"
          unless $db->can('handle_jmap');
        my $server     = $db->access_data();
        my $proxy_id   = $accountid;
        my $backend_id = $server->{backendAccountId} // '';
        my ($session)  = $db->fetch_session({});
        my $acct = ($session->{accounts} || {})->{$backend_id} || {};

        # Rewrite backend accountId → proxy accountId in primaryAccounts values.
        my %primary;
        my $up_primary = $session->{primaryAccounts} || {};
        for my $urn (keys %$up_primary) {
          my $v = $up_primary->{$urn};
          $primary{$urn} = (defined $v && $v eq $backend_id) ? $proxy_id : $v;
        }

        return ['session_caps', {
          accountCapabilities => $acct->{accountCapabilities} || {},
          capabilities        => $session->{capabilities}     || {},
          name                => $acct->{name},
          isReadOnly          => $acct->{isReadOnly} ? $JSON::true : $JSON::false,
          isPersonal          => $acct->{isPersonal} ? $JSON::true : $JSON::false,
          primaryAccounts     => \%primary,
        }];
      }
```

- [ ] **Step 2: Verify the command responds against the running proxy**

The stack from Task 3 is still up (`--jmap`). Exercise the worker command directly via the management sync path is not exposed, so verify indirectly in Task 5 (the `/session` consumer). For a quick standalone check, confirm the branch parses:

Run: `perl -c bin/jmap-proxy.pl`
Expected: `bin/jmap-proxy.pl syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add bin/jmap-proxy.pl
git commit -m "proxy: add session_caps worker command for passthrough capability fetch"
```

---

### Task 5: Live-fetch capability assembly in `do_session`

Make `do_session` fetch upstream capabilities for each passthrough account in the pool and merge them into the served session.

**Files:**
- Modify: `bin/jmap-proxy.pl` — `do_session` sub (~lines 1153-1258)

**Interfaces:**
- Consumes: `session_caps` worker command (Task 4); `get_pool` (returns accounts with a `type` field).
- Produces: `/session` whose `accounts.{aid}.accountCapabilities` reflect the upstream for jmap accounts; top-level `capabilities` is the union of core + every account's contributed capabilities; `primaryAccounts` honours upstream primaries for jmap accounts.

- [ ] **Step 1: Confirm the current `/session` omits upstream caps**

Stack is up from Task 3. Check the served capabilities for the passthrough account:

```bash
curl -s -u user1:password http://localhost:9000/session \
  | perl -MJSON::PP -0777 -ne 'my $s=decode_json($_); print join(",", sort keys %{$s->{accounts}{user1}{accountCapabilities}}), "\n"'
```
Expected (before the fix): the hardcoded IMAP set (e.g. `urn:ietf:params:jmap:mail,urn:ietf:params:jmap:submission,...`), independent of what Cyrus actually advertises.

- [ ] **Step 2: Refactor the per-account capability build into a helper**

In `bin/jmap-proxy.pl`, just above `sub do_session`, add a helper that builds the *IMAP* accountCapabilities for one account (extracted verbatim from the current inline `accountCapabilities` hash):

```perl
sub _imap_account_capabilities {
  my ($a) = @_;
  return {
    'urn:ietf:params:jmap:mail' => {
      maxMailboxesPerEmail         => undef,
      maxMailboxDepth              => undef,
      maxSizeMailboxName           => 490,
      maxSizeAttachmentsPerEmail   => 50_000_000,
      emailQuerySortOptions        => [qw(
        receivedAt sentAt size subject from to id
        hasKeyword allInThreadHaveKeyword someInThreadHaveKeyword
      )],
      mayCreateTopLevelMailbox     => JSON::true,
    },
    'urn:ietf:params:jmap:submission' => { maxDelayedSend => 0 },
    'urn:ietf:params:jmap:mdn'   => {},
    'urn:ietf:params:jmap:quota' => {},
    ($a->{caldavURL} ? ('urn:ietf:params:jmap:calendars' => {
      maxCalendarsPerEvent     => 1,
      minDateTime              => '1970-01-01T00:00:00Z',
      maxDateTime              => '2099-12-31T23:59:59Z',
      maxExpandedQueryDuration => 'P2Y',
      maxParticipantsPerEvent  => undef,
      mayCreateCalendar        => JSON::true,
    },
    'urn:ietf:params:jmap:principals' => {
      currentUserPrincipalId => 'me',
    }) : ()),
    ($a->{carddavURL} ? ('urn:ietf:params:jmap:contacts' => {
      maxAddressBooksPerCard => 1,
      mayCreateAddressBook   => JSON::true,
    }) : ()),
  };
}
```

- [ ] **Step 3: Rewrite `do_session` to fan out `session_caps` for jmap accounts**

In `bin/jmap-proxy.pl`, replace the body of the `get_pool` callback inside `do_session` (from `my $accounts = {};` down to the `$req->respond(...)` that emits the session) with the following. It collects per-account capability records first, then assembles:

```perl
      my @pool = @{$pool->{accounts} || []};

      # Collect each account's capability record (async for jmap accounts).
      my %caprec;   # accountid => { accountCapabilities, capabilities, name, isReadOnly, isPersonal, primaryAccounts }
      my @jmap = grep { ($_->{type} // '') eq 'jmap' } @pool;

      my $assemble = sub {
        my $accounts = {};
        my %top_caps;
        my (%primary_for);   # urn => accountid (first wins)

        for my $a (@pool) {
          my $aid  = $a->{accountid};
          my $rec  = $caprec{$aid};
          my $acct_caps;

          if (($a->{type} // '') eq 'jmap' && $rec) {
            $acct_caps = $rec->{accountCapabilities} || {};
            # union upstream top-level capabilities
            $top_caps{$_} = $rec->{capabilities}{$_} for keys %{ $rec->{capabilities} || {} };
            # honour upstream primaries
            for my $urn (keys %{ $rec->{primaryAccounts} || {} }) {
              $primary_for{$urn} //= $rec->{primaryAccounts}{$urn};
            }
          }
          else {
            $acct_caps = _imap_account_capabilities($a);
            $top_caps{$_} //= {} for keys %$acct_caps;
            $primary_for{'urn:ietf:params:jmap:mail'}       //= $aid;
            $primary_for{'urn:ietf:params:jmap:submission'} //= $aid;
            $primary_for{'urn:ietf:params:jmap:calendars'}  //= $aid if $a->{caldavURL};
            $primary_for{'urn:ietf:params:jmap:contacts'}   //= $aid if $a->{carddavURL};
          }

          $accounts->{$aid} = {
            name       => ($rec && $rec->{name}) || $a->{email} || $aid,
            isPersonal => JSON::true,
            isReadOnly => ($rec && $rec->{isReadOnly}) ? JSON::true : JSON::false,
            accountCapabilities => $acct_caps,
          };
        }

        my $session = {
          capabilities => {
            'urn:ietf:params:jmap:core' => {
              maxSizeUpload => 50_000_000,
              maxConcurrentUpload => 4,
              maxSizeRequest => 10_000_000,
              maxConcurrentRequests => 4,
              maxCallsInRequest => 16,
              maxObjectsInGet => 4096,
              maxObjectsInSet => 4096,
              collationAlgorithms => [],
            },
            %top_caps,
          },
          accounts => $accounts,
          primaryAccounts => \%primary_for,
          username => ($pool[0] ? $pool[0]{email} : ''),
          apiUrl => "$BASEURL/jmap",
          downloadUrl => "$BASEURL/raw/{accountId}/{blobId}/{name}",
          uploadUrl => "$BASEURL/upload/{accountId}",
          eventSourceUrl => "$BASEURL/eventsource?types={types}&closeafter={closeafter}&ping={ping}",
          state => sha1_hex(join(',', sort map { $_->{accountid} } @pool)),
        };

        $req->respond([200, 'ok', {
          'Content-Type'  => 'application/json',
          'Cache-Control' => 'no-cache, no-store',
        }, JSON::XS::encode_json($session)]);
      };

      unless (@jmap) { $assemble->(); return; }

      my $pending = scalar @jmap;
      for my $a (@jmap) {
        my $aid = $a->{accountid};
        send_backend_request($aid, 'session_caps', {}, sub {
          $caprec{$aid} = shift;
          $assemble->() if --$pending == 0;
        }, sub {
          my $err = shift;
          warn "session_caps failed for $aid: $err\n";   # degrade to core-only
          $caprec{$aid} = undef;
          $assemble->() if --$pending == 0;
        });
      }
```

- [ ] **Step 4: Restart and verify upstream caps now appear**

```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh --jmap clean
curl -s -u user1:password http://localhost:9000/session \
  | perl -MJSON::PP -0777 -ne 'my $s=decode_json($_); print join(",", sort keys %{$s->{accounts}{user1}{accountCapabilities}}), "\n"'
```
Expected (after the fix): the set Cyrus actually advertises for the account (compare to `curl -s -u user1:password http://localhost:8080/jmap/session` — the proxy's account caps should match Cyrus's account caps for that account).

- [ ] **Step 5: Commit**

```bash
git add bin/jmap-proxy.pl
git commit -m "proxy: assemble /session capabilities from upstream for passthrough accounts"
```

---

### Task 6: Teach the test adapter to provision passthrough accounts

**Files:**
- Modify: `/Users/brong/src/jmap-perl/bin/restart-test-proxy.sh` (write a `passthrough` flag into `test-config.json` in `--jmap` mode)
- Modify: `/Users/brong/src/JMAP-TestSuite/lib/JMAP/TestSuite/ServerAdapter/JMAPProxy.pm` (add `passthrough` attribute; branch in `_create_pristine_account`)

**Interfaces:**
- Consumes: the proxy's `POST /api/accounts` signup_jmap routing (triggered by a `sessionUrl` field — confirmed at `bin/jmap-proxy.pl:3746`).
- Produces: in `--jmap` mode, `pristine_account` / `pool_account_pair` create passthrough accounts pointing at Cyrus's native JMAP.

- [ ] **Step 1: Write the `passthrough` flag into the proxy-mode test config**

In `bin/restart-test-proxy.sh`, the `test-config.json` heredoc currently ends with `"cyrus_backend" : true`. Add a passthrough flag whose value depends on `$BACKEND`. Change the heredoc's `cyrus_backend` line region from:

```bash
  "cyrus_hierarchy_separator"  : ".",
  "cyrus_backend"              : true
}
TESTCONFIG
```
to:
```bash
  "cyrus_hierarchy_separator"  : ".",
  "cyrus_backend"              : true,
  "passthrough"                : $( [ "$BACKEND" = "jmap" ] && echo true || echo false )
}
TESTCONFIG
```

- [ ] **Step 2: Add the `passthrough` attribute to the adapter**

In `JMAP/TestSuite/ServerAdapter/JMAPProxy.pm`, after the `cyrus_http_url` attribute (~line 98), add:

```perl
# When true (set by restart-test-proxy.sh --jmap), pristine accounts are
# created as JMAP passthrough accounts pointing at Cyrus's native JMAP,
# so the full suite exercises the passthrough path.
has passthrough => (
  is      => 'ro',
  default => 0,
);
```

- [ ] **Step 3: Branch `_create_pristine_account` on passthrough mode**

In `JMAP/TestSuite/ServerAdapter/JMAPProxy.pm`, replace the `$content = encode_json({...})` block in `_create_pristine_account` (the IMAP payload) with a conditional payload:

```perl
  my $content;
  if ($self->passthrough) {
    # Register a JMAP passthrough account pointing at Cyrus's native JMAP.
    $content = encode_json({
      accountid  => $user,
      sessionUrl => $self->cyrus_http_url . "/jmap/session",
      username   => $user,
      password   => $self->cyrus_password,
      authType   => 'basic',
      %extra,
    });
  }
  else {
    $content = encode_json({
      accountid  => $user,
      type       => 'imap',
      username   => $user,
      password   => $self->cyrus_password,
      imapHost   => $self->cyrus_host,
      imapPort   => $self->cyrus_port,
      imapSSL    => 1,
      caldavURL  => $self->cyrus_http_url,
      carddavURL => $self->cyrus_http_url,
      %extra,
    });
  }
```

(`%extra` carries `poolid` for `pool_account_pair`; the signup_jmap path accepts `poolid` — see `bin/jmap-proxy.pl:551`.)

- [ ] **Step 4: Verify a pristine passthrough account is created**

```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh --jmap clean
JMAP_SERVER_ADAPTER_FILE=/tmp/jmap-proxy-test/test-config.json \
  perl -I/Users/brong/src/JMAP-TestSuite/lib -MJMAP::TestSuite -e '
    my $ts = JMAP::TestSuite->new;
    my $a = $ts->server->pristine_account;
    print "created: ", $a->accountId, "\n";
  '
```
Expected: prints `created: jt-...`. Then confirm it is a passthrough account:
```bash
sqlite3 /tmp/jmap-proxy-test/accounts.sqlite3 "SELECT accountid,type FROM accounts WHERE type='jmap';"
```
Expected: lists `user1|jmap` and the newly created `jt-...|jmap`.

- [ ] **Step 5: Commit (two repos)**

```bash
cd /Users/brong/src/jmap-perl
git add bin/restart-test-proxy.sh
git commit -m "test-proxy: write passthrough flag into --jmap test config"

cd /Users/brong/src/JMAP-TestSuite
git add lib/JMAP/TestSuite/ServerAdapter/JMAPProxy.pm
git commit -m "JMAPProxy adapter: provision passthrough accounts in passthrough mode"
```

---

### Task 7: Full verification run, fix regressions, update docs

**Files:**
- Modify (as needed): `JMAP/JmapDB.pm`, `bin/jmap-proxy.pl` for any passthrough-specific failures
- Modify: `CLAUDE.md`, `docs/superpowers/specs/2026-06-30-jmap-passthrough-design.md` (status), and project memory

**Interfaces:**
- Consumes: everything above.
- Produces: a passing (vs. baseline) `--jmap` suite run and updated docs.

- [ ] **Step 1: Capture the Cyrus-native baseline**

```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh clean        # imap mode brings up Cyrus
./bin/run-jmap-tests.sh --direct
```
Record the `Files=.../Result:` line from `/tmp/jmap-cyrus-direct-results.txt`. This is the upper bound (Cyrus-native behaviour).

- [ ] **Step 2: Run the suite through passthrough**

```bash
./bin/restart-test-proxy.sh --jmap clean
./bin/run-jmap-tests.sh
```
Record the `Files=.../Result:` line from `/tmp/jmap-test-results.txt`.

- [ ] **Step 3: Diff passthrough failures against the baseline**

For any suite that fails in passthrough mode but passes in `--direct`, it is a passthrough bug. Re-run the single failing suite verbosely to see the JMAP-level difference:

```bash
./bin/run-jmap-tests.sh t/<Suite>/<failing>.t
```
Common culprits to check, in order: accountId fields not rewritten (extend `_rewrite_method_ids` `@ID_KEYS` if a method uses another id key); blobId corruption in `proxy_blob` (apply field-targeted rewriting); `state`/`sessionState` mismatches.

- [ ] **Step 4: Fix and re-run until passthrough matches the baseline**

Apply minimal fixes, committing each with a descriptive message, and re-run Step 2 until the passthrough `Result:` matches the `--direct` baseline (allowing for tests that genuinely cannot pass through a proxy — document any such exclusions in the spec).

- [ ] **Step 5: Update docs and memory**

Update `CLAUDE.md` (add a passthrough status line under the data-model/architecture notes), set the spec's **Status** to reflect completion, and update project memory (`MEMORY.md` "Still TODO" → move JMAP backend passthrough to done with the verified result).

- [ ] **Step 6: Commit**

```bash
cd /Users/brong/src/jmap-perl
git add CLAUDE.md docs/superpowers/specs/2026-06-30-jmap-passthrough-design.md
git commit -m "docs: mark JMAP passthrough complete with verified test results"
```

---

## Self-Review

**Spec coverage:**
- §1 Unify DB file → Task 1. ✓
- §2 Type-aware credential reads (auth, verify_credentials, _account_details_child) → Task 3. ✓
- §3 Live session assembly → Task 5. ✓
- §4 `session_caps` command → Task 4. ✓
- §5 Adapter passthrough provisioning → Task 6. ✓
- §6 Verification → Task 7. ✓
- §Risk accountId rewriting → Task 2 (implemented up front as structured rewriting, since the `user1` collision is certain — this firms up the spec's "fallback" into a definite task). ✓
- Out-of-scope items (SSE/push, IMAP auth decrypt inconsistency, caps caching, Fastmail-real verification) → correctly not implemented. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows the command and expected output.

**Type consistency:** `_rewrite_method_ids($triples, $from, $to)` used identically in Task 2 request/response and referenced nowhere else. `session_caps` return keys (`accountCapabilities`, `capabilities`, `name`, `isReadOnly`, `isPersonal`, `primaryAccounts`) produced in Task 4 are exactly the keys consumed by `$assemble` in Task 5. `_imap_account_capabilities($a)` defined and called in Task 5. `passthrough` attribute defined and used in Task 6.

**Deviation flagged for the user:** Task 2 implements structured accountId rewriting up front rather than as a post-failure fallback (the spec's contingency), because the proxy id `user1` is certain to collide with `user1@example.com` in test data.
