# Passthrough Dispatch + Cross-Account Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the JMAP passthrough proxy dispatch a multi-call request by routing each call to its account's upstream, batching consecutive same-upstream calls into one forwarded request, threading `createdIds` and resolving cross-batch `ResultReference`s, and copying objects across accounts (native-forward for same-credential passthrough pairs, blob-shuffle otherwise).

**Architecture:** The algorithmic core (batch grouping, JSON-Pointer-with-`*` evaluation) moves into a new pure, unit-testable module `JMAP::Dispatch`. `bin/jmap-proxy.pl`'s `_do_jmap_request` is rewritten to use it. The per-account worker's `handle_jmap` is generalised from a single proxy→backend id pair to an id *map* so one forwarded batch can span several backend accountIds under one login. Cross-account copy reuses the existing `_copy_emails`/`_copy_blobs` orchestration, with `fetch_blobs`/`store_blob` taught to download-from / upload-to an upstream for passthrough accounts.

**Tech Stack:** Perl 5, AnyEvent (parent event loop, never blocks), DBI/SQLite, HTTP::Tiny, JSON::XS. Tests: `Test::More` + `prove`. Integration: Cyrus Docker test server, JMAP-TestSuite.

## Global Constraints

- **Never block the parent.** All upstream HTTP / per-account DB work happens in a child worker; the parent only routes and assembles via `send_backend_request` callbacks.
- **Per-account DB file is `$datadir/$accountid.sqlite3`**; account `type` comes from the `type` column in `accounts.sqlite3` (`jmap` for passthrough).
- **Upstream key:** passthrough account → its `cred_fingerprint`; IMAP/other → `"imap:$accountid"` (unique, never shares a batch).
- **Credential fingerprint:** `sha256_hex(join("\0", apiUrl, username, authType, secret))`, `secret` = decrypted password/token. Computed in the worker; only the fingerprint (never raw creds) reaches the parent. `NULL` for non-passthrough accounts.
- **Batches run strictly in order**; the accumulated `createdIds` map is carried forward across batches and returned in the response.
- **`%KNOWN_CAPABILITIES`** bounds what `/session` advertises and what `do_jmap` accepts; unchanged here.
- Commit after each task. Work on the `jmap-passthrough` branch.

---

### Task 1: Credential fingerprint (`accounts` schema v2 + computation)

**Files:**
- Modify: `bin/jmap-proxy.pl` — `$ACCOUNTS_SCHEMA_VERSION` and `_migrate_accounts_db` (~line 835); `signup_jmap` handler (~line 516); `update_settings` handler (~line 774); `_account_details_child` (~line 1066); `get_pool` handler (~line 890 region).
- Test: `t/cred-fingerprint.t` (create)

**Interfaces:**
- Produces: `JMAP::JmapDB::cred_fingerprint(\%server)` → the fingerprint string for a jserver-style hash with keys `apiUrl`, `username`, `authType`, and a decrypted `secret`. The `accounts` table gains a nullable `cred_fingerprint` column. `get_pool`/`_account_details_child` return `cred_fingerprint` and `backendAccountId` for jmap accounts.

- [ ] **Step 1: Write the failing unit test for the fingerprint function**

Create `t/cred-fingerprint.t`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

my $dir;
BEGIN { require File::Temp; $dir = File::Temp::tempdir(CLEANUP => 1); $ENV{JMAP_DATADIR} = $dir; }

use lib '.';
use JMAP::JmapDB;

my $fp1 = JMAP::JmapDB::cred_fingerprint({
  apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
});
my $fp2 = JMAP::JmapDB::cred_fingerprint({
  apiUrl => 'https://up.example/jmap', username => 'u1', authType => 'basic', secret => 'pw',
});
my $fp3 = JMAP::JmapDB::cred_fingerprint({
  apiUrl => 'https://up.example/jmap', username => 'u2', authType => 'basic', secret => 'pw',
});

is($fp1, $fp2, 'same credentials produce the same fingerprint');
isnt($fp1, $fp3, 'different username produces a different fingerprint');
like($fp1, qr/^[0-9a-f]{64}$/, 'fingerprint is a sha256 hex string');

done_testing;
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `perl -Ilib t/cred-fingerprint.t`
Expected: FAIL — "Undefined subroutine &JMAP::JmapDB::cred_fingerprint".

- [ ] **Step 3: Add the fingerprint function to `JMAP/JmapDB.pm`**

Add near the top of `JMAP/JmapDB.pm` (after the existing `use` lines):

```perl
use Digest::SHA qw(sha256_hex);

# Stable fingerprint identifying the upstream login. Two passthrough accounts
# with the same fingerprint share one set of upstream credentials.
sub cred_fingerprint {
    my ($server) = @_;
    return sha256_hex(join("\0",
        $server->{apiUrl}   // '',
        $server->{username} // '',
        $server->{authType} // 'basic',
        $server->{secret}   // '',
    ));
}
```

- [ ] **Step 4: Run the unit test to confirm it passes**

Run: `perl -Ilib t/cred-fingerprint.t`
Expected: PASS (3 assertions).

- [ ] **Step 5: Add the schema-v2 migration**

In `bin/jmap-proxy.pl`, change `my $ACCOUNTS_SCHEMA_VERSION = 1;` to `my $ACCOUNTS_SCHEMA_VERSION = 2;`. Then in `_migrate_accounts_db`, replace the incremental-migration comment block with a real v2 migration (place it before the closing `}` of the sub):

```perl
  if ($v < 2) {
    $dbh->begin_work;
    eval {
      $dbh->do("ALTER TABLE accounts ADD COLUMN cred_fingerprint TEXT");
      $dbh->do('PRAGMA user_version = 2');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "migration to v2 failed: $@" }
    warn "accounts.sqlite3: migrated to schema version 2\n";
    $v = 2;
  }
```

(The fresh-install branch already runs at `$ACCOUNTS_SCHEMA_VERSION`, so a new DB starts at v2; add the column to the fresh `CREATE TABLE accounts` statement too:)

Change the fresh-install `CREATE TABLE accounts` line to:

```perl
      $dbh->do("CREATE TABLE accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT, needs_backfill INTEGER NOT NULL DEFAULT 1, cred_fingerprint TEXT)");
```

- [ ] **Step 6: Compute and store the fingerprint at signup_jmap and update_settings**

In `bin/jmap-proxy.pl` `signup_jmap` handler, after `$db->setuser({...})` is called, add (the worker holds `$dbh` to accounts.sqlite3 and the decrypted args):

```perl
        my $fp = JMAP::JmapDB::cred_fingerprint({
          apiUrl   => $api_url,
          username => $args->{username} // '',
          authType => $args->{authType} || 'basic',
          secret   => $args->{password} // '',
        });
        $dbh->do("UPDATE accounts SET cred_fingerprint = ? WHERE accountid = ?", {}, $fp, $final_aid);
```

In the `update_settings` handler's jmap branch (after `$db->setuser({...})`), add the same computation keyed by `$accountid`, using `$session->{apiUrl}` for `apiUrl`:

```perl
          my $fp = JMAP::JmapDB::cred_fingerprint({
            apiUrl   => $session->{apiUrl},
            username => $args->{username} // '',
            authType => $args->{authType} || 'basic',
            secret   => $args->{password} // '',
          });
          $dbh->do("UPDATE accounts SET cred_fingerprint = ? WHERE accountid = ?", {}, $fp, $accountid);
```

- [ ] **Step 7: Expose fingerprint + backendAccountId via `_account_details_child`**

In `bin/jmap-proxy.pl` `_account_details_child`, the jmap branch (returns `configured`/`username`/`type`) — add `backendAccountId` from the jserver row and read `cred_fingerprint` from accounts.sqlite3. Change the jmap branch to:

```perl
  if ($has_jserver) {
    my $j = eval { $udb->selectrow_hashref("SELECT * FROM jserver LIMIT 1") } || {};
    return {
      configured       => (defined $j->{username} && length $j->{username} ? 1 : 0),
      username         => $j->{username},
      type             => 'jmap',
      backendAccountId => $j->{backendAccountId},
    };
  }
```

`cred_fingerprint` lives in `accounts.sqlite3`, so it is already available to `get_pool` (which SELECTs from accounts). Update the `get_pool` SELECT (~line 890s) to include it: change `"SELECT email, accountid, type FROM accounts WHERE poolid = ? ORDER BY accountid"` to `"SELECT email, accountid, type, cred_fingerprint FROM accounts WHERE poolid = ? ORDER BY accountid"`.

- [ ] **Step 8: Verify migration + fingerprint end-to-end**

Run:
```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh --jmap clean
sqlite3 /tmp/jmap-proxy-test/accounts.sqlite3 "PRAGMA user_version; SELECT accountid, cred_fingerprint FROM accounts;"
```
Expected: `user_version` = `2`; `user1` has a 64-hex `cred_fingerprint`.

- [ ] **Step 9: Commit**

```bash
git add JMAP/JmapDB.pm bin/jmap-proxy.pl t/cred-fingerprint.t
git commit -m "accounts: add cred_fingerprint (schema v2) for same-upstream detection"
```

---

### Task 2: `JMAP::Dispatch::group_batches` — order-preserving batch grouping

**Files:**
- Create: `JMAP/Dispatch.pm`
- Test: `t/dispatch-batches.t` (create)

**Interfaces:**
- Produces: `JMAP::Dispatch::group_batches(\@methodCalls, \%key_for_aid, $default_aid)` → arrayref of batches. Each batch is `{ key => <upstream key>, calls => [ [pos, call], ... ] }` where `pos` is the 0-based index in the original `methodCalls`. Consecutive calls sharing the same upstream key are grouped; order is preserved. A call's account is `call->[1]{accountId}` (or `$default_aid` if absent); for `*/copy` calls the account is `call->[1]{fromAccountId}`. `key_for_aid` maps accountid → upstream key; an unknown accountid falls back to `"imap:$aid"`.

- [ ] **Step 1: Write the failing test**

Create `t/dispatch-batches.t`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my %key = (A => 'up1', B => 'up1', C => 'up2');

# consecutive A,B (same key up1) batch together; C breaks to a new batch;
# then A again is a third batch (order preserved, not merged with the first).
my @calls = (
  ['Mailbox/get', { accountId => 'A' }, '0'],
  ['Email/get',   { accountId => 'B' }, '1'],
  ['Email/get',   { accountId => 'C' }, '2'],
  ['Email/get',   { accountId => 'A' }, '3'],
);

my $batches = JMAP::Dispatch::group_batches(\@calls, \%key, 'A');

is(scalar @$batches, 3, 'three batches: [A,B], [C], [A]');
is($batches->[0]{key}, 'up1', 'batch 0 key up1');
is_deeply([map { $_->[0] } @{$batches->[0]{calls}}], [0,1], 'batch 0 positions 0,1');
is($batches->[1]{key}, 'up2', 'batch 1 key up2');
is_deeply([map { $_->[0] } @{$batches->[1]{calls}}], [2], 'batch 1 position 2');
is_deeply([map { $_->[0] } @{$batches->[2]{calls}}], [3], 'batch 2 position 3');

# default account used when accountId absent
my @calls2 = (['Core/echo', {}, 'x']);
my $b2 = JMAP::Dispatch::group_batches(\@calls2, \%key, 'B');
is($b2->[0]{key}, 'up1', 'absent accountId uses default account key');

# unknown account falls back to imap:<aid>
my @calls3 = (['Email/get', { accountId => 'Z' }, 'z']);
my $b3 = JMAP::Dispatch::group_batches(\@calls3, \%key, 'A');
is($b3->[0]{key}, 'imap:Z', 'unknown account falls back to imap:<aid> key');

# copy uses fromAccountId for the account
my @calls4 = (['Email/copy', { fromAccountId => 'C', accountId => 'A' }, 'c']);
my $b4 = JMAP::Dispatch::group_batches(\@calls4, \%key, 'A');
is($b4->[0]{key}, 'up2', 'copy keys off fromAccountId');

done_testing;
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `perl -Ilib t/dispatch-batches.t`
Expected: FAIL — "Can't locate JMAP/Dispatch.pm".

- [ ] **Step 3: Create `JMAP/Dispatch.pm` with `group_batches`**

```perl
package JMAP::Dispatch;
use strict;
use warnings;

# Map a single method call to the accountid it targets.
sub _call_account {
    my ($call, $default_aid) = @_;
    my $args = $call->[1] // {};
    if ($call->[0] =~ m{/copy$}) {
        return $args->{fromAccountId} // $default_aid;
    }
    return $args->{accountId} // $default_aid;
}

# Group consecutive method calls sharing one upstream key into batches,
# preserving order. Returns [ { key => $k, calls => [ [pos, call], ... ] }, ... ].
sub group_batches {
    my ($calls, $key_for_aid, $default_aid) = @_;
    my @batches;
    for my $pos (0 .. $#$calls) {
        my $call = $calls->[$pos];
        my $aid  = _call_account($call, $default_aid);
        my $key  = $key_for_aid->{$aid} // "imap:$aid";
        if (@batches && $batches[-1]{key} eq $key) {
            push @{ $batches[-1]{calls} }, [$pos, $call];
        }
        else {
            push @batches, { key => $key, calls => [ [$pos, $call] ] };
        }
    }
    return \@batches;
}

1;
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `perl -Ilib t/dispatch-batches.t`
Expected: PASS (8 assertions).

- [ ] **Step 5: Commit**

```bash
git add JMAP/Dispatch.pm t/dispatch-batches.t
git commit -m "Dispatch: group_batches() — order-preserving same-upstream batching"
```

---

### Task 3: `JMAP::Dispatch::resolve_pointer` — JSON Pointer with JMAP `*` semantics

**Files:**
- Modify: `JMAP/Dispatch.pm`
- Test: `t/dispatch-pointer.t` (create)

**Interfaces:**
- Produces: `JMAP::Dispatch::resolve_pointer($data, $path)` → `($ok, $value)`. Evaluates a JMAP ResultReference path (RFC 8620 §3.7): a JSON Pointer where a `*` token maps the remainder over each element of an array and flattens one level. Returns `(1, $value)` on success or `(0, undef)` if any token is missing / type-mismatched.

- [ ] **Step 1: Write the failing test**

Create `t/dispatch-pointer.t`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my $data = {
  accountId => 'A',
  list => [ { id => 'x1', sub => { v => 1 } }, { id => 'x2', sub => { v => 2 } } ],
  ids  => ['a','b'],
};

is_deeply([JMAP::Dispatch::resolve_pointer($data, '/accountId')], [1, 'A'], 'plain key');
is_deeply([JMAP::Dispatch::resolve_pointer($data, '/ids')], [1, ['a','b']], 'array value');
is_deeply([JMAP::Dispatch::resolve_pointer($data, '/list/*/id')], [1, ['x1','x2']], 'star maps over array');
is_deeply([JMAP::Dispatch::resolve_pointer($data, '/list/0/sub/v')], [1, 1], 'index then nested');
is((JMAP::Dispatch::resolve_pointer($data, '/missing'))[0], 0, 'missing key fails');
is((JMAP::Dispatch::resolve_pointer($data, '/accountId/x'))[0], 0, 'descend into scalar fails');
is((JMAP::Dispatch::resolve_pointer($data, '/list/*/nope'))[0], 1, 'star over missing subkey yields list of undefs (ok)');

done_testing;
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `perl -Ilib t/dispatch-pointer.t`
Expected: FAIL — "Undefined subroutine &JMAP::Dispatch::resolve_pointer".

- [ ] **Step 3: Add `resolve_pointer` to `JMAP/Dispatch.pm`**

Add to `JMAP/Dispatch.pm` (before the final `1;`):

```perl
# Evaluate a JMAP ResultReference path against $data. A "*" token maps the
# remaining path over each element of the current array and flattens one level.
# Returns (1, $value) or (0, undef).
sub resolve_pointer {
    my ($data, $path) = @_;
    my @tokens = split m{/}, $path, -1;
    shift @tokens;   # leading empty token from the leading "/"
    return _resolve_tokens($data, \@tokens);
}

sub _resolve_tokens {
    my ($node, $tokens) = @_;
    return (1, $node) unless @$tokens;
    my ($tok, @rest) = @$tokens;
    $tok =~ s{~1}{/}g; $tok =~ s{~0}{~}g;   # JSON Pointer unescaping

    if ($tok eq '*') {
        return (0, undef) unless ref $node eq 'ARRAY';
        my @out;
        for my $el (@$node) {
            my ($ok, $v) = _resolve_tokens($el, \@rest);
            return (0, undef) unless $ok;
            if (ref $v eq 'ARRAY') { push @out, @$v } else { push @out, $v }
        }
        return (1, \@out);
    }
    if (ref $node eq 'HASH') {
        return (0, undef) unless exists $node->{$tok};
        return _resolve_tokens($node->{$tok}, \@rest);
    }
    if (ref $node eq 'ARRAY' && $tok =~ /^\d+$/) {
        return (0, undef) unless $tok <= $#$node;
        return _resolve_tokens($node->[$tok], \@rest);
    }
    return (0, undef);
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `perl -Ilib t/dispatch-pointer.t`
Expected: PASS (7 assertions).

- [ ] **Step 5: Commit**

```bash
git add JMAP/Dispatch.pm t/dispatch-pointer.t
git commit -m "Dispatch: resolve_pointer() — JMAP ResultReference path evaluator"
```

---

### Task 4: Generalise id rewriting to a proxy↔backend map

**Files:**
- Modify: `JMAP/JmapDB.pm` — `_rewrite_method_ids` (~line 17), `handle_jmap` (~line 193); worker `jmap` command (`bin/jmap-proxy.pl` ~line 694)
- Test: `t/jmapdb-rewrite-map.t` (create)

**Interfaces:**
- Produces: `JMAP::JmapDB::_rewrite_method_ids_map($triples, \%map)` — rewrites each `accountId`/`fromAccountId`/`toAccountId` field via `%map` (exact-match lookup; absent keys untouched). `handle_jmap($request, \%fwd_map, \%rev_map)` accepts optional forward (proxy→backend) and reverse (backend→proxy) maps; when omitted it builds the single-pair map from its own account (backwards compatible). The worker `jmap` command passes an optional `idmap` arg through.

- [ ] **Step 1: Write the failing test for the map rewrite**

Create `t/jmapdb-rewrite-map.t`:

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
  ['Email/get',  { accountId => 'pA', ids => ['m1'] }, '0'],
  ['Email/copy', { fromAccountId => 'pA', toAccountId => 'pB', accountId => 'pB' }, '1'],
  ['Email/set',  { accountId => 'pA', create => { k => { x => 'pA stays in body' } } }, '2'],
];

JMAP::JmapDB::_rewrite_method_ids_map($calls, { pA => 'bA', pB => 'bB' });

is($calls->[0][1]{accountId}, 'bA', 'accountId mapped');
is($calls->[1][1]{fromAccountId}, 'bA', 'fromAccountId mapped');
is($calls->[1][1]{toAccountId},   'bB', 'toAccountId mapped');
is($calls->[1][1]{accountId},     'bB', 'copy accountId mapped');
is($calls->[2][1]{create}{k}{x}, 'pA stays in body', 'body untouched');

done_testing;
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `perl -Ilib t/jmapdb-rewrite-map.t`
Expected: FAIL — "Undefined subroutine &JMAP::JmapDB::_rewrite_method_ids_map".

- [ ] **Step 3: Add the map rewrite and refactor the single-pair one to use it**

In `JMAP/JmapDB.pm`, replace the existing `_rewrite_method_ids` with both functions:

```perl
my @ID_KEYS = qw(accountId fromAccountId toAccountId);

# Rewrite accountId-style fields via a {from => to} map (exact match).
sub _rewrite_method_ids_map {
    my ($triples, $map) = @_;
    for my $triple (@{ $triples || [] }) {
        my $args = $triple->[1];
        next unless ref $args eq 'HASH';
        for my $k (@ID_KEYS) {
            my $v = $args->{$k};
            $args->{$k} = $map->{$v} if defined $v && !ref $v && defined $map->{$v};
        }
    }
    return $triples;
}

# Backwards-compatible single-pair rewrite.
sub _rewrite_method_ids {
    my ($triples, $from, $to) = @_;
    return _rewrite_method_ids_map($triples, { $from => $to });
}
```

- [ ] **Step 4: Run the map test (and the existing rewrite test) to confirm pass**

Run: `perl -Ilib t/jmapdb-rewrite-map.t && perl -Ilib t/jmapdb-rewrite.t`
Expected: both PASS.

- [ ] **Step 5: Make `handle_jmap` accept optional maps**

In `JMAP/JmapDB.pm` `handle_jmap`, change the signature and the two rewrite calls. Replace the head of the sub through the request rewrite with:

```perl
sub handle_jmap {
    my ($Self, $request, $fwd_map, $rev_map) = @_;

    my $server     = $Self->access_data();
    my $proxy_id   = $Self->{accountid};
    my $backend_id = $server->{backendAccountId}
        or die "No backendAccountId configured for $proxy_id\n";
    my $api_url    = $server->{apiUrl}
        or die "No apiUrl configured for $proxy_id\n";

    # Default to the single-account pair when no explicit map is supplied.
    $fwd_map //= { $proxy_id   => $backend_id };
    $rev_map //= { $backend_id => $proxy_id };

    _rewrite_method_ids_map($request->{methodCalls}, $fwd_map);
    my $req_json = encode_json($request);
```

And change the response rewrite line from `_rewrite_method_ids($response->{methodResponses}, $backend_id, $proxy_id);` to:

```perl
    _rewrite_method_ids_map($response->{methodResponses}, $rev_map);
```

- [ ] **Step 6: Thread an optional `idmap` through the worker `jmap` command**

In `bin/jmap-proxy.pl`, the `jmap` command handler currently calls `$db->handle_jmap($args)`. The dispatcher (Task 5) will pass the request plus the id maps inside `$args` under reserved keys `_fwd_map`/`_rev_map`. Change the passthrough branch:

```perl
      if ($cmd eq 'jmap') {
        my $result;
        if ($db->can('handle_jmap')) {
          my $fwd = delete $args->{_fwd_map};
          my $rev = delete $args->{_rev_map};
          $result = $db->handle_jmap($args, $fwd, $rev);
        } else {
          $result = $api->handle_request($args);
        }
```

(Leave the rest of the `jmap` handler — the sessionState computation — unchanged. Deleting the reserved keys before forwarding keeps them out of the upstream request.)

- [ ] **Step 7: Syntax check + regression run**

Run: `perl -c -I. bin/jmap-proxy.pl && perl -Ilib t/jmapdb-rewrite.t t/jmapdb-rewrite-map.t`
Expected: `syntax OK`; both tests PASS.

- [ ] **Step 8: Commit**

```bash
git add JMAP/JmapDB.pm bin/jmap-proxy.pl t/jmapdb-rewrite-map.t
git commit -m "JmapDB: id rewriting via a proxy<->backend map; handle_jmap takes optional maps"
```

---

### Task 5: Rewrite `_do_jmap_request` — routing, batching, createdIds, ResultReferences

**Files:**
- Modify: `bin/jmap-proxy.pl` — `_do_jmap_request` (~line 1444) and add a helper `_account_keymap`
- Test: integration via JMAP-TestSuite + a focused curl check (this is async parent code; unit coverage lives in Tasks 2/3)

**Interfaces:**
- Consumes: `JMAP::Dispatch::group_batches`, `JMAP::Dispatch::resolve_pointer`, `__accounts__` `get_pool` (now returning `type`, `cred_fingerprint`, `backendAccountId`).
- Produces: `_do_jmap_request` forwards each batch with the correct id map, threads `createdIds`, resolves cross-batch `ResultReference`s, and assembles a response carrying `methodResponses`, `createdIds`, and `sessionState`. Single-account requests behave exactly as before.

- [ ] **Step 1: Establish the current single-account behaviour still works (RED guard)**

Stack from Task 1. Confirm a normal request works pre-change:
```bash
./bin/restart-test-proxy.sh --jmap clean
curl -s -u user1:password -H 'Content-Type: application/json' http://localhost:9000/jmap \
  -d '{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],"methodCalls":[["Mailbox/get",{"accountId":"user1"},"0"]]}' \
  -w '\nhttp: %{http_code}\n' | head -c 200
```
Expected: HTTP 200 with a `Mailbox/get` response. (Baseline to preserve.)

- [ ] **Step 2: Add `require JMAP::Dispatch` near the other requires**

In `bin/jmap-proxy.pl`, add `use JMAP::Dispatch;` alongside the existing `use` statements at the top of the file.

- [ ] **Step 3: Rewrite `_do_jmap_request`**

Replace the entire body of `_do_jmap_request` (from `sub _do_jmap_request {` to its closing `}`) with the routing/batching engine below. It fetches the pool key-map once (async), groups batches, then processes them strictly in order, threading `createdIds` and resolving cross-batch `ResultReference`s; a batch whose `key` route is `orchestrate` (cross-upstream copy, Task 6) is handled by `_do_copy_call`.

```perl
sub _do_jmap_request {
  my ($req, $accountid, $data) = @_;

  warn "JMAP REQUEST ($accountid): " . join(', ', map { $_->[0] } @{$data->{methodCalls} || []}) . "\n";
  warn "JMAP REQUEST BODY: " . $json->encode($data) . "\n" if $ENV{JMAP_DEBUG};
  $stat{jmap_method_calls} += scalar @{$data->{methodCalls} || []};

  # 1. Look up routing info for the whole pool, then build per-account maps.
  send_backend_request('__accounts__', 'get_pool', { accountid => $accountid }, sub {
    my $pool = shift;
    my (%key_for_aid, %backend_for_aid, %type_for_aid);
    for my $a (@{ $pool->{accounts} || [] }) {
      my $aid = $a->{accountid};
      $type_for_aid{$aid}    = $a->{type} // '';
      $backend_for_aid{$aid} = $a->{backendAccountId};
      $key_for_aid{$aid} = (($a->{type} // '') eq 'jmap' && $a->{cred_fingerprint})
        ? "fp:$a->{cred_fingerprint}" : "imap:$aid";
    }
    $key_for_aid{$accountid} //= "imap:$accountid";

    my $calls   = $data->{methodCalls} || [];
    my $batches = JMAP::Dispatch::group_batches($calls, \%key_for_aid, $accountid);

    my $n = scalar @$calls;
    my @responses = (undef) x $n;
    my %created_ids = %{ $data->{createdIds} || {} };
    my %resp_by_tag;   # tag => response triple (for cross-batch ResultReference)

    # Resolve any cross-batch ResultReference in a call's args, in place.
    my $resolve_refs = sub {
      my ($call, $batch_tags) = @_;
      my $args = $call->[1];
      return 1 unless ref $args eq 'HASH';
      for my $k (grep { /^#/ } keys %$args) {
        my $ref = $args->{$k};
        next unless ref $ref eq 'HASH' && defined $ref->{resultOf};
        next if $batch_tags->{ $ref->{resultOf} };   # same batch: upstream resolves it
        my $prev = $resp_by_tag{ $ref->{resultOf} };
        if (!$prev || $prev->[0] ne ($ref->{name} // '')) {
          $args->{_jmap_ref_error} = $k; return 0;
        }
        my ($ok, $val) = JMAP::Dispatch::resolve_pointer($prev->[1], $ref->{path} // '');
        if (!$ok) { $args->{_jmap_ref_error} = $k; return 0; }
        (my $real = $k) =~ s/^#//;
        delete $args->{$k};
        $args->{$real} = $val;
      }
      return 1;
    };

    my $finish = sub {
      my @flat = grep { defined } @responses;
      $stat{jmap_method_errors} += grep { $_->[0] eq 'error' } @flat;
      my $result = {
        methodResponses => \@flat,
        (%created_ids ? (createdIds => \%created_ids) : ()),
        sessionState    => _compute_session_state($accountid),
      };
      my $body = $json->encode($result);
      warn "JMAP RESPONSE: " . length($body) . " bytes\n";
      warn "JMAP RESPONSE BODY: $body\n" if $ENV{JMAP_DEBUG};
      $req->respond([200, 'ok', { 'Content-Type' => 'application/json' }, $body]);
    };

    # Process batches strictly in order.
    my $i = 0;
    my $next_batch; $next_batch = sub {
      if ($i > $#$batches) { return $finish->() }
      my $batch = $batches->[$i++];

      # Cross-upstream copy batch (Task 6): single copy call routed to orchestration.
      if ($batch->{key} eq 'orchestrate') {
        my ($pos, $call) = @{ $batch->{calls}[0] };
        _do_copy_call($call->[0], $call->[1], $call->[2], $accountid, sub {
          my $resp = shift;
          if (ref($resp->[0]) eq 'ARRAY') { $responses[$pos] = $resp->[0]; }
          else                            { $responses[$pos] = $resp; }
          $resp_by_tag{ $responses[$pos][2] } = $responses[$pos];
          $next_batch->();
        }, sub {
          $responses[$pos] = ['error', { type => 'serverError', message => "$_[0]" }, $call->[2]];
          $next_batch->();
        });
        return;
      }

      my %batch_tags = map { $_->[1][2] => 1 } @{ $batch->{calls} };
      my (@calls, @positions);
      for my $pc (@{ $batch->{calls} }) {
        my ($pos, $call) = @$pc;
        unless ($resolve_refs->($call, \%batch_tags)) {
          $responses[$pos] = ['error', { type => 'invalidResultReference' }, $call->[2]];
          next;
        }
        push @calls, $call; push @positions, $pos;
      }
      unless (@calls) { return $next_batch->() }

      # Build forward/reverse id maps for the accounts referenced in this batch.
      my (%fwd, %rev);
      for my $call (@calls) {
        for my $aid (grep { defined } @{$call->[1]}{qw(accountId fromAccountId toAccountId)}) {
          my $b = $backend_for_aid{$aid};
          if (defined $b) { $fwd{$aid} = $b; $rev{$b} = $aid; }
        }
      }

      my %batch_data = (
        %$data,
        methodCalls => \@calls,
        createdIds  => \%created_ids,
        _fwd_map    => \%fwd,
        _rev_map    => \%rev,
      );
      # Forward to a worker on this upstream — the first account in the batch.
      my $worker_aid = _call_account_for($calls[0], $accountid);
      send_backend_request($worker_aid, 'jmap', \%batch_data, sub {
        my $r = shift;
        my %pos_by_tag = map { $calls[$_][2] => $positions[$_] } 0..$#calls;
        for my $resp (@{ $r->{methodResponses} || [] }) {
          my $pos = $pos_by_tag{ $resp->[2] };
          if (defined $pos) { $responses[$pos] = $resp; $resp_by_tag{ $resp->[2] } = $resp; }
        }
        $created_ids{$_} = $r->{createdIds}{$_} for keys %{ $r->{createdIds} || {} };
        $next_batch->();
      }, sub {
        my $err = shift;
        for my $idx (0..$#calls) {
          $responses[$positions[$idx]] = ['error', { type => 'serverError', message => "$err" }, $calls[$idx][2]];
        }
        $next_batch->();
      });
    };
    $next_batch->();
  }, sub {
    my $err = shift;
    $req->respond([200, 'ok', { 'Content-Type' => 'application/json' },
      $json->encode({ methodResponses => [['error', { type => 'serverError', message => "$err" }, 'a']] })]);
  });
}

# Account a single call targets (mirror of Dispatch::_call_account for the worker pick).
sub _call_account_for {
  my ($call, $default) = @_;
  my $args = $call->[1] // {};
  return ($call->[0] =~ m{/copy$}) ? ($args->{fromAccountId} // $default) : ($args->{accountId} // $default);
}
```

(Note: cross-upstream copy routing — assigning the `orchestrate` key — is added in Task 6. Until then, `group_batches` never produces an `orchestrate` key, so copy calls route to their `fromAccountId`'s batch. That is fine for same-upstream copies and is exactly the Task 6 follow-up.)

- [ ] **Step 4: Syntax check**

Run: `perl -c -I. bin/jmap-proxy.pl`
Expected: `bin/jmap-proxy.pl syntax OK`.

- [ ] **Step 5: Verify single-account behaviour preserved + createdIds back-reference**

```bash
./bin/restart-test-proxy.sh --jmap clean
# single-account create with a #creationId back-reference across two calls
curl -s -u user1:password -H 'Content-Type: application/json' http://localhost:9000/jmap -d '{
 "using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],
 "methodCalls":[
   ["Mailbox/set",{"accountId":"user1","create":{"a":{"name":"refbox","parentId":null}}},"0"],
   ["Mailbox/get",{"accountId":"user1","#ids":{"resultOf":"0","name":"Mailbox/set","path":"/created/a/id"}},"1"]
 ]}' -w '\nhttp: %{http_code}\n' | head -c 500
```
Expected: HTTP 200; the `Mailbox/get` response returns the just-created mailbox (the back-reference resolved — natively, since both calls are one batch). Confirms the rewrite didn't regress single-account dispatch or createdIds.

- [ ] **Step 6: Run the full --jmap suite to confirm no regression**

```bash
./bin/run-jmap-tests.sh
grep -E '^(Files=|Result:)' /tmp/jmap-test-results.txt | tail -2
```
Expected: failure set no larger than the pre-task baseline recorded in `.superpowers/sdd/progress.md` (Cyrus-native failures + Email/copy). Investigate any NEW failure before committing.

- [ ] **Step 7: Commit**

```bash
git add bin/jmap-proxy.pl
git commit -m "proxy: route+batch jmap dispatch by upstream, thread createdIds, resolve cross-batch refs"
```

---

### Task 6: Cross-upstream copy routing (`orchestrate`) + native same-upstream copy

**Files:**
- Modify: `JMAP/Dispatch.pm` — `group_batches` (accept a copy-route classifier); `bin/jmap-proxy.pl` — pass the classifier from `_do_jmap_request`
- Test: `t/dispatch-copy-route.t` (create)

**Interfaces:**
- Produces: `group_batches(\@calls, \%key_for_aid, $default_aid, $copy_route)` where `$copy_route->($call)` returns `'orchestrate'` to force a standalone cross-upstream-copy batch, or `undef` to route normally. A `*/copy` whose from & to share an upstream key routes normally (native, in-batch); otherwise it is `orchestrate`.

- [ ] **Step 1: Write the failing test**

Create `t/dispatch-copy-route.t`:

```perl
#!/usr/bin/perl
use strict; use warnings;
use Test::More;
use lib '.';
use JMAP::Dispatch;

my %key = (A => 'fp:1', B => 'fp:1', C => 'fp:2');
# classifier: copy is 'orchestrate' unless from & to share a key
my $route = sub {
  my ($call) = @_;
  return undef unless $call->[0] =~ m{/copy$};
  my $a = $call->[1]{fromAccountId}; my $b = $call->[1]{accountId};
  return (($key{$a}//'') eq ($key{$b}//'')) ? undef : 'orchestrate';
};

# same-upstream copy A->B : normal (batched on fp:1)
my $b1 = JMAP::Dispatch::group_batches(
  [['Email/copy',{fromAccountId=>'A',accountId=>'B'},'0']], \%key, 'A', $route);
is($b1->[0]{key}, 'fp:1', 'same-upstream copy stays on its upstream key');

# cross-upstream copy A->C : orchestrate (standalone)
my $b2 = JMAP::Dispatch::group_batches(
  [['Email/copy',{fromAccountId=>'A',accountId=>'C'},'0']], \%key, 'A', $route);
is($b2->[0]{key}, 'orchestrate', 'cross-upstream copy is orchestrate');

# orchestrate never merges with a neighbouring normal call
my $b3 = JMAP::Dispatch::group_batches([
  ['Email/get',{accountId=>'A'},'0'],
  ['Email/copy',{fromAccountId=>'A',accountId=>'C'},'1'],
  ['Email/get',{accountId=>'A'},'2'],
], \%key, 'A', $route);
is(scalar @$b3, 3, 'orchestrate is isolated into its own batch');
is($b3->[1]{key}, 'orchestrate', 'middle batch is the orchestrate copy');

done_testing;
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `perl -Ilib t/dispatch-copy-route.t`
Expected: FAIL (4th arg ignored → cross-upstream copy not isolated; `is` mismatches).

- [ ] **Step 3: Extend `group_batches` with the copy-route classifier**

In `JMAP/Dispatch.pm`, change `group_batches` to take and honour `$copy_route`:

```perl
sub group_batches {
    my ($calls, $key_for_aid, $default_aid, $copy_route) = @_;
    my @batches;
    for my $pos (0 .. $#$calls) {
        my $call = $calls->[$pos];
        my $route = $copy_route ? $copy_route->($call) : undef;
        my $key;
        if (defined $route) {
            $key = $route;   # e.g. 'orchestrate' — always its own batch
            push @batches, { key => $key, calls => [ [$pos, $call] ], isolated => 1 };
            next;
        }
        my $aid = _call_account($call, $default_aid);
        $key = $key_for_aid->{$aid} // "imap:$aid";
        if (@batches && $batches[-1]{key} eq $key && !$batches[-1]{isolated}) {
            push @{ $batches[-1]{calls} }, [$pos, $call];
        }
        else {
            push @batches, { key => $key, calls => [ [$pos, $call] ] };
        }
    }
    return \@batches;
}
```

- [ ] **Step 4: Run the new test + the Task-2 test (regression)**

Run: `perl -Ilib t/dispatch-copy-route.t t/dispatch-batches.t`
Expected: both PASS.

- [ ] **Step 5: Pass the classifier from `_do_jmap_request`**

In `bin/jmap-proxy.pl` `_do_jmap_request`, after `%key_for_aid` is built, define the classifier and pass it to `group_batches`:

```perl
    my $copy_route = sub {
      my ($call) = @_;
      return undef unless $call->[0] =~ m{^(Blob|Email)/copy$};
      my $fa = $call->[1]{fromAccountId};
      my $ta = $call->[1]{accountId};
      my $fk = $key_for_aid{$fa // ''} // '';
      my $tk = $key_for_aid{$ta // ''} // '';
      # native-forward only when both are passthrough (fp:) AND same key
      return undef if $fk eq $tk && $fk =~ /^fp:/;
      return 'orchestrate';
    };
    my $batches = JMAP::Dispatch::group_batches($calls, \%key_for_aid, $accountid, $copy_route);
```

(`CalendarEvent`/`ContactCard` copy are deliberately excluded — they continue to flow through normal batches as ordinary JMAP get/set forwarding, which already works.)

- [ ] **Step 6: Syntax check + verify same-upstream native copy**

This step needs the same-credentials adapter config (Task 8) for a full automated check; for now verify syntax and that cross-upstream copy still reaches orchestration (the existing blob path, fixed in Task 7):

Run: `perl -c -I. bin/jmap-proxy.pl`
Expected: `syntax OK`.

- [ ] **Step 7: Commit**

```bash
git add JMAP/Dispatch.pm bin/jmap-proxy.pl t/dispatch-copy-route.t
git commit -m "Dispatch: route cross-upstream copies to orchestration, native-forward same-upstream"
```

---

### Task 7: Passthrough-aware `fetch_blobs` / `store_blob` (blob-shuffle for cross-upstream/mixed)

**Files:**
- Modify: `bin/jmap-proxy.pl` — `fetch_blobs` handler (~line 623), `store_blob` handler (~line 664)
- Test: integration (curl reproductions + `Email/copy/basic.t` in --jmap)

**Interfaces:**
- Consumes: `JMAP::JmapDB::proxy_blob`, `JMAP::JmapDB::proxy_upload`, `handle_jmap`.
- Produces: `fetch_blobs` returns `{ type, path, is_temp }` for passthrough sources by downloading from the upstream; `store_blob` for a passthrough dest uploads to the upstream and returns `{ blobId => <upstream blobId> }`.

- [ ] **Step 1: Make `fetch_blobs` passthrough-aware**

In `bin/jmap-proxy.pl` `fetch_blobs` handler, before the existing local-store logic, add a passthrough branch. At the top of the handler (after `my %result;`):

```perl
        if ($db->can('handle_jmap')) {
          for my $blobid (@{$args->{ids} || []}) {
            my $up_blob = $blobid;
            if ($blobid =~ /^m-(.+)$/) {
              # resolve the email's upstream blobId via Email/get
              my $eid = $1;
              my $r = $db->handle_jmap({
                using => ['urn:ietf:params:jmap:core','urn:ietf:params:jmap:mail'],
                methodCalls => [['Email/get', { accountId => $accountid, ids => [$eid], properties => ['blobId'] }, 'g']],
              });
              my ($resp) = grep { $_->[2] eq 'g' } @{ $r->{methodResponses} || [] };
              my $email = $resp && $resp->[0] eq 'Email/get' ? $resp->[1]{list}[0] : undef;
              unless ($email && $email->{blobId}) { $result{$blobid} = undef; next; }
              $up_blob = $email->{blobId};
            }
            my ($type, $body) = eval { $db->proxy_blob($up_blob, 'copy', 'application/octet-stream') };
            if (!defined $body) { $result{$blobid} = undef; next; }
            my $fh = File::Temp->new(DIR => "$datadir/tmp", UNLINK => 0, SUFFIX => '.blob');
            binmode $fh; print $fh $body; close $fh;
            $result{$blobid} = { type => $type || 'application/octet-stream', path => $fh->filename, is_temp => 1 };
          }
          return ['fetch_blobs', \%result];
        }
```

- [ ] **Step 2: Make `store_blob` passthrough-aware**

In `bin/jmap-proxy.pl` `store_blob` handler, at the top (after reading `$src`/`$type`/`$is_temp`):

```perl
        if ($db->can('handle_jmap')) {
          my $r = $db->proxy_upload($type, $src);
          unlink $src if $is_temp;
          return ['store_blob', { blobId => $r->{blobId} }];
        }
```

(The existing IMAP logic — insert into `jfiles`, hardlink, return `f-<id>` — stays as the fallback below.)

- [ ] **Step 3: Syntax check**

Run: `perl -c -I. bin/jmap-proxy.pl`
Expected: `bin/jmap-proxy.pl syntax OK`.

- [ ] **Step 4: Verify `Email/copy` between two different-credential passthrough accounts**

```bash
./bin/restart-test-proxy.sh --jmap clean
./bin/run-jmap-tests.sh t/Email/copy/basic.t 2>&1 | grep -E '\.t |Result:'
```
Expected: `t/Email/copy/basic.t ... ok` and `Result: PASS`. (`pool_account_pair` makes two different-credential passthrough accounts → blob-shuffle path.)

- [ ] **Step 5: Regression — IMAP-mode Email/copy still passes**

```bash
./bin/restart-test-proxy.sh clean
./bin/run-jmap-tests.sh t/Email/copy/basic.t 2>&1 | grep -E '\.t |Result:'
```
Expected: PASS (IMAP branches of fetch_blobs/store_blob unchanged).

- [ ] **Step 6: Commit**

```bash
git add bin/jmap-proxy.pl
git commit -m "proxy: passthrough-aware fetch_blobs/store_blob for cross-upstream blob copy"
```

---

### Task 8: Test-adapter configurations + copy matrix

**Files:**
- Modify: `/Users/brong/src/JMAP-TestSuite/lib/JMAP/TestSuite/ServerAdapter/JMAPProxy.pm`
- Modify: `bin/jmap-proxy.pl`'s `restart-test-proxy.sh` is already passthrough-aware (Task 6 of the prior plan); no change needed there.
- Test: a new proxy-side integration test `t/passthrough-copy-matrix.t` (create) exercising same-credentials native-forward via curl.

**Interfaces:**
- Produces: adapter methods `same_creds_account_pair` (one Cyrus login exposing two backend accountIds via delegation → two passthrough accounts, same fingerprint) and `mixed_account_pair` (one IMAP + one passthrough account in a pool). Used by copy tests; skip when not in passthrough mode.

- [ ] **Step 1: Add `same_creds_account_pair` to the adapter**

In `JMAP/TestSuite/ServerAdapter/JMAPProxy.pm`, add a method that creates a primary Cyrus user and a shared user, grants the primary access to the shared user's mailbox (so the primary's JMAP session lists both accountIds), and registers two passthrough proxy accounts using the **primary's** credentials but different `backendAccountId`. Add:

```perl
sub same_creds_account_pair {
  my ($self) = @_;
  die "same_creds_account_pair requires passthrough mode\n" unless $self->passthrough;

  my $num    = $USERNUM++;
  my $primary = "jt-$STARTTIME-$$-$num-p";
  my $shared  = "jt-$STARTTIME-$$-$num-s";
  my $sep = $self->_detected_separator;

  my $client = $self->imap_client;
  die "create primary" unless $client->create("user$sep$primary");
  die "create shared"  unless $client->create("user$sep$shared");
  $client->setacl("user$sep$primary", $primary, "lrswipkxtecdan");
  $client->setacl("user$sep$shared",  $shared,  "lrswipkxtecdan");
  # grant the primary full rights on the shared account so its JMAP session lists it
  $client->setacl("user$sep$shared", $primary, "lrswipkxtecdan");

  my $mgmt = $self->mgmt_uri =~ s{/\z}{}r;
  my $lwp  = LWP::UserAgent->new;
  # backendAccountId for each is the Cyrus accountId; the proxy resolves it from
  # the upstream session (primaryAccounts/accounts). Register both as passthrough
  # accounts authenticating as $primary; they get the same cred_fingerprint.
  for my $aid ($primary, $shared) {
    my $res = $lwp->post("$mgmt/api/accounts",
      Content_Type => 'application/json',
      Content => encode_json({
        accountid  => $aid,
        sessionUrl => $self->cyrus_http_url . "/jmap",
        username   => $primary,          # same login for both
        password   => $self->cyrus_password,
        authType   => 'basic',
        poolid     => $primary,
      }));
    die "register $aid: " . $res->status_line unless $res->is_success;
  }
  return ($self->_make_account($primary), $self->_make_account($shared));
}
```

(Note: this exercises the proxy's same-fingerprint detection. Whether Cyrus exposes the shared account under the primary's session depends on the test container's delegation support; if the second account isn't visible, the test in Step 3 documents it as skipped — the native-forward path is still unit-covered by Tasks 4/6.)

- [ ] **Step 2: Add `mixed_account_pair` to the adapter**

```perl
sub mixed_account_pair {
  my ($self) = @_;
  die "mixed_account_pair requires passthrough mode\n" unless $self->passthrough;
  # account A: passthrough; account B: IMAP — same pool
  my $a = $self->_create_pristine_account;                 # passthrough (Task 6 default)
  my $num = $USERNUM++;
  my $b = "jt-$STARTTIME-$$-$num-imap";
  my $sep = $self->_detected_separator;
  $self->imap_client->create("user$sep$b") or die "create imap user";
  $self->imap_client->setacl("user$sep$b", $b, "lrswipkxtecdan");
  my $mgmt = $self->mgmt_uri =~ s{/\z}{}r;
  my $res = LWP::UserAgent->new->post("$mgmt/api/accounts",
    Content_Type => 'application/json',
    Content => encode_json({
      accountid => $b, type => 'imap', username => $b, password => $self->cyrus_password,
      imapHost => $self->cyrus_host, imapPort => $self->cyrus_port, imapSSL => 1,
      caldavURL => $self->cyrus_http_url, carddavURL => $self->cyrus_http_url,
      poolid => $a->accountId,
    }));
  die "register imap: " . $res->status_line unless $res->is_success;
  return ($a, $self->_make_account($b));
}
```

- [ ] **Step 3: Add a proxy-side native-forward smoke test**

Create `t/passthrough-copy-matrix.t` in the jmap-perl repo — a curl-driven test (skips unless `CYRUS_URL` set) that registers two same-login passthrough accounts (primary + shared, as in Step 1, via the Cyrus mgmt + proxy mgmt APIs), imports a message into the primary, issues a single `Email/copy` from primary→shared, and asserts the response is a normal `Email/copy` with `created` (not an error) — confirming the native-forward batch path. Use the existing `t/cyrus-proxy.t` skip/setup pattern for env handling.

```perl
#!/usr/bin/perl
use strict; use warnings;
use Test::More;
use JSON::XS; use HTTP::Tiny;
unless ($ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL} && $ENV{JMAP_MGMT_URL}) {
  plan skip_all => "set CYRUS_URL, JMAP_PROXY_URL, JMAP_MGMT_URL (and run a --jmap proxy + Cyrus) to enable";
}
# ... register primary+shared same-login passthrough accounts via JMAP_MGMT_URL,
#     import a message to primary, Email/copy primary->shared, assert created.
# (Implementer: mirror the curl flow validated during Task 7 verification.)
fail("implement native-forward copy assertion") unless 0;
done_testing;
```

NOTE: this test file is a thin integration harness; the implementer fills the registration/copy/assert body using the exact mgmt payloads from Step 1 and the `Email/copy` request shape from the spec. It must make a real assertion on the `Email/copy` response (`created` present, no top-level error).

- [ ] **Step 4: Run the copy matrix**

```bash
cd /Users/brong/src/jmap-perl
./bin/restart-test-proxy.sh --jmap clean
CYRUS_URL=http://localhost:8080 JMAP_PROXY_URL=http://localhost:9000 JMAP_MGMT_URL=http://localhost:8081 \
  perl -Ilib t/passthrough-copy-matrix.t
```
Expected: PASS (native-forward copy returns `created`). If Cyrus delegation prevents the shared account from being visible under the primary's session, mark the test `skip` with a clear diagnostic and record the limitation.

- [ ] **Step 5: Commit (two repos)**

```bash
cd /Users/brong/src/jmap-perl
git add t/passthrough-copy-matrix.t
git commit -m "test: native-forward cross-account copy smoke test (same-credentials passthrough)"

cd /Users/brong/src/JMAP-TestSuite
git add lib/JMAP/TestSuite/ServerAdapter/JMAPProxy.pm
git commit -m "JMAPProxy adapter: same_creds_account_pair + mixed_account_pair configs"
```

---

## Self-Review

**Spec coverage:**
- §A upstream key → Task 5 (`%key_for_aid` build) + Task 1 (fingerprint). ✓
- §B batching → Task 2 (`group_batches`) + Task 5 (use it). ✓
- §C createdIds plumbing → Task 5 (`%created_ids` threading). ✓
- §C2 cross-batch ResultReference → Task 3 (`resolve_pointer`) + Task 5 (`resolve_refs`). ✓
- §D copy routing → Task 6 (classifier) + Task 7 (blob path) + native via Tasks 4/6. ✓
- §E credential fingerprint → Task 1. ✓
- §F passthrough fetch_blobs/store_blob → Task 7. ✓
- §G adapter configs → Task 8. ✓

**Placeholder scan:** Task 8 Step 3 ships a deliberately-stubbed test harness (`fail(...) unless 0`) with explicit fill-in instructions — flagged, not silent; the implementer must replace it with a real assertion using the Step-1 payloads. All other steps contain complete code.

**Type consistency:** `group_batches` signature gains `$copy_route` in Task 6 (Task 2 callers pass 3 args; Perl ignores the absent 4th — compatible). `_rewrite_method_ids_map($triples,\%map)` used in Task 4 and consumed by `handle_jmap`'s maps. `_fwd_map`/`_rev_map` reserved keys set in Task 5, consumed/deleted in Task 4's worker handler. Batch shape `{key, calls=>[[pos,call]]}` consistent across Tasks 2/5/6. `fetch_blobs` return shape `{type,path,is_temp}` consistent Task 7 ↔ existing `_copy_emails`/`_copy_blobs`.

**Build-order soundness:** Task 4 (worker reads `_fwd_map`) lands before Task 5 (parent sends it); Task 3 (`resolve_pointer`) before Task 5 (uses it); Task 2 before Tasks 5/6. ✓
