# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A proxy server that bridges IMAP/CalDAV/CardDAV backends to the JMAP protocol
(RFC 8620/8621, JMAP Calendars, JMAP Contacts). It also supports direct
JMAP-to-JMAP passthrough for backends that already speak JMAP (Cyrus, Fastmail).
One instance serves many users, each with their own backend account.

Email/calendar/contact **conversion logic** lives in three standalone CPAN-style
modules (`Data::JSEmail`, `Text::JSContact`, `Text::JSCalendar`); the **sync and
protocol** code lives here and in `Net::*Talk`.

## The process model (read ARCHITECTURE.md before touching `bin/jmap-proxy.pl`)

`bin/jmap-proxy.pl` is a single-process server that forks children over socketpairs:

- **Parent** — AnyEvent HTTP event loop. Does HTTP routing, request dispatch,
  response callbacks, and child management. **It must NEVER BLOCK.**
- **`__accounts__` child** — owns `accounts.sqlite3` only (account CRUD, tokens, auth).
- **Per-account child** — owns ALL IMAP/CalDAV/CardDAV connections, the per-account
  SQLite file, sync, and JMAP method handling. Blocking JSON read/write loop.

Hard rules that are easy to violate:

- **NEVER in the parent**: `firstsync`, `sync_imap`, `sync_folders`, IMAP connections,
  `JMAP::ImapDB->new()`, `setuser()`, `DBI->connect`, or any per-account DB op.
- **Backfill and sync/jmap MUST run in separate child processes.** The jmap/sync
  worker is keyed by `$accountid`; the backfill worker is keyed by `"$accountid:backfill"`
  (separate fork, same DB). `run_backend_worker` strips a trailing `:[^:]+$` to recover
  the real accountid for DB lookup. The parent drives the loop via `prod_backfill($accountid)`.
  **Never call `$db->backfill()` inside the sync/jmap worker command handler.**
- **Never call `get_user()` outside a transaction** — Perl autovivification of
  `$Self->{t}{user}` leaves a phantom `$Self->{t}={}` and corrupts later transaction state.
  Cache values you need inside the transaction for use in closures.

## Code layout

- `bin/jmap-proxy.pl` — the server (parent + worker loop + cross-account `/copy` orchestration).
- `JMAP/DB.pm` — base DB class (SQLite schema, transactions, sync state, query snapshot cache).
  - `JMAP/ImapDB.pm` (← DB) — IMAP/CalDAV/CardDAV sync. `FastmailDB`, `GmailDB`, `AOLDB` extend it.
  - `JMAP/JmapDB.pm` — standalone, for JMAP passthrough backends.
- `JMAP/Dispatch.pm` — pure, unit-testable dispatch core: `check_accounts` (a missing
  `accountId` is `invalidArguments`, one outside the session is `accountNotFound` — the
  proxy never defaults it), `group_batches` (order-preserving same-upstream batching) and
  `resolve_pointer` (JSON Pointer with JMAP `*` semantics).
  No I/O, no DB — keep it that way; `t/dispatch-*.t` covers it.
- `JMAP/API.pm` — JMAP request handler; dispatches to per-datatype method modules in
  `JMAP/API/` (`Email`, `Mailbox`, `Thread`, `Calendar`, `Contact`, `Submission`,
  `StorageNode`, `MDN`, `Quota`, `Preferences`).
- `JMAP/Sync/` — backend sync drivers (`Standard`, `Gmail`, `Fastmail`, `AOL`, `Common`).
- `JMAP/OAuth/` — OAuth2 signup (`Google`, `Fastmail`, `OIDC`, `PACC`, `PKCE`).
- `JMAP/CredentialStore.pm` — pluggable at-rest encryption for stored credentials.

## Passthrough request dispatch (`_do_jmap_request`)

One JMAP request can span several accounts on different upstreams. The parent groups the
method calls into batches by **upstream key** and runs the batches strictly in order,
threading `createdIds` forward and resolving cross-batch `ResultReference`s itself.

- **Upstream key**: passthrough account → `fp:<cred_fingerprint>`; anything else →
  `imap:<accountid>` (unique, so it never shares a batch).
  `cred_fingerprint` = sha256(apiUrl, username, authType, secret), computed in the worker —
  only the fingerprint, never the raw credentials, reaches the parent.
- **Copy routing**: a `/copy` call whose two sides share one passthrough upstream is
  forwarded natively; otherwise it goes to parent-level orchestration (`_do_copy_call`),
  which shuffles blobs via `fetch_blobs`/`store_blob`.
  The classifier must list **every** `/copy` method `_do_copy_call` handles — a method
  missing from that regex is forwarded to a worker and comes back `unknownMethod`.
  (`t/dispatch-copy-route.t` passes its own stub classifier, so it does **not** catch this.)
- **Server-injected responses**: an orchestrated copy may return several triples (e.g. the
  `Email/set` for `onSuccessDestroyOriginal`). `@responses` is position-indexed, so extras
  go in `@extra_responses` and are appended after all responses. Dropping them silently
  loses the `Email/set` from the client's view.

## Multi-account passthrough (one login, several accounts)

An upstream login often exposes more than its own account (delegated/shared accounts).
Register one proxy account per upstream account, all with the same `username`/`password`
but a different `backendAccountId` (validated against the upstream session's `accounts`).

- `email` is the **proxy-side login** and must stay unique, so it falls back to the
  `backendAccountId` for any account not bound to the primary.
- Consequently the credential lookups in the `auth` / `verify_credentials` worker commands
  must read the account DB's single `jserver` row — **never** key it on `email`, which does
  not match the stored upstream username for a delegated binding.
- Accounts sharing a login share a `cred_fingerprint`, which is exactly what makes a copy
  between them native-forwardable. Before this existed, no two proxy accounts could share a
  fingerprint, so the native-forward branch was unreachable.

## Data model

- `accounts.sqlite3` — global: which accounts exist, type, tokens, auth, pool grouping (`poolid`),
  and `cred_fingerprint` (schema v2) identifying the upstream login for passthrough accounts
  (NULL for everything else).
- one `<accountid>.sqlite3` per account — all synced mail/calendar/contact state plus
  the `iserver` table (backend connection config, including auto-detected `imapSep`).
  Passthrough accounts instead keep a single `jserver` row (upstream credentials,
  session/api/upload/download URLs, `backendAccountId`, capabilities).
  Schema version is tracked; recent additions include the `jqueries` snapshot cache
  (schema v10) used by `queryChanges`.

## Local development & testing

Requires a local Cyrus test server (Docker image
`ghcr.io/cyrusimap/cyrus-docker-test-server`) on IMAP `:8143`, HTTP/JMAP/CalDAV/CardDAV
`:8080`, mgmt `:8001`. Cyrus accepts any password; default users are `user1`–`user5`.

```bash
# Start/restart the test proxy (frontend :9000, mgmt :8081). `clean` wipes the DB
# AND recreates the Cyrus container (needed to clear tombstones that corrupt
# Mailbox/changes). `--jmap` registers the test user as a passthrough account.
bin/restart-test-proxy.sh clean

# Run the full JMAP-TestSuite against the proxy (expects JMAP-TestSuite checked out;
# override path with JMAP_TESTSUITE=). Results go to /tmp/jmap-test-results.txt.
bin/run-jmap-tests.sh

# Run one suite or one test file
bin/run-jmap-tests.sh t/Email/
bin/run-jmap-tests.sh t/Calendar/get.t

# Test directly against Cyrus's native JMAP, bypassing the proxy (to triage whether a
# failure is the proxy's fault or the backend's)
bin/run-jmap-tests.sh --direct

# Local Perl unit/integration tests (module conversion + end-to-end against Cyrus).
# cyrus-proxy.t and integration.t skip unless CYRUS_URL/CYRUS_USER/CYRUS_PASS are set.
CYRUS_URL=http://localhost:8080 CYRUS_USER=user1 CYRUS_PASS=password prove -lv t/

# Passthrough integration tests (delegated-account registration, native-forward copy).
# These provision their own Cyrus users, so run against a --jmap stack.
bin/restart-test-proxy.sh --jmap clean
CYRUS_URL=http://localhost:8080 JMAP_PROXY_URL=http://localhost:9000 \
  JMAP_MGMT_URL=http://localhost:8081 \
  prove -lv t/passthrough-delegated-account.t t/passthrough-copy-matrix.t
```

Testing a Cyrus fix end to end: build Cyrus in a `dar` container for the branch's worktree,
`docker commit` that container as a builder image, build the test-server image from it with
the test-server Dockerfile's stage 1 swapped for `FROM <that image> AS builder`, then
`CYRUS_IMAGE=<image> bin/restart-test-proxy.sh clean` and `bin/run-jmap-tests.sh --direct`.

Debugging: set `JMAP_DEBUG=1` to log full request/response bodies. Proxy stderr goes
to `/tmp/jmap-proxy.log` when started via `restart-test-proxy.sh`.

Test-account hygiene: `any_account` reuses `user1` and accumulates state across runs —
use `pristine_account` for tests that create named resources (mailboxes, calendars,
addressbooks). `pool_account_pair` creates two pristine accounts in one pool for
cross-account `/copy` tests. In passthrough mode, `same_creds_account_pair` gives a
primary plus a delegated account under **one** login (shared fingerprint → native-forward
copy), and `mixed_account_pair` gives a passthrough + IMAP pair (always orchestrated).

**Creating Cyrus users: use the separator Cyrus reports, not the config.**
`test-config.json` says `cyrus_hierarchy_separator: "."` but Cyrus actually reports `/`
(the adapter's `_detected_separator` queries NAMESPACE). Creating `user.NAME` makes a stray
top-level mailbox rather than a user; Cyrus then answers HTTP with **503** and logs
`could not autoprovision calendars for userid NAME: Invalid user`, while IMAP login still
succeeds — which looks exactly like a broken container. Always create `user/NAME`.
The Cyrus container's own mgmt API (`PUT :8001/api/<user>`) needs a request **body**;
a bare PUT dies `need data` in `Cyrus::AccountSync` and returns 500.

Reading the suite results: the raw failure count drifts as the Cyrus container is recreated,
so the meaningful gate is a **same-session passthrough-vs-`--direct` diff** — a failure that
also fails `--direct` is Cyrus's, not the proxy's.
`t/AddressBook/changes` and `t/Calendar/changes` are occasionally flaky under full-suite
load; re-run them in isolation before believing a failure.

`run-jmap-tests.sh` with no arguments runs **all of `t/`**. It used to run a hand-picked
directory list, which silently skipped `t/core/`, `t/Blob/` and the top-level `t/*.t` for
months and hid five real proxy bugs (ResultReference validation, dropped error responses,
Blob/copy arguments, downloadUrl `{type}`, unknown-mailbox moves). Never narrow it again.

On the full suite (166 files, 2026-09-07) IMAP mode is **166/166 against the proxy** and
154/166 `--direct`: the five Cyrus bugs in the `testsuite-fixes` branch plus the
unimplemented `Identity/set`, and seven accountId tests (`t/core/accountId-required.t` and
six `foreign-account.t`) where Cyrus accepts a missing accountId, accepts a foreign
`fromAccountId` on an empty `/copy`, or lacks the method. So the diff is clean.

**Every `api_*` method lives in exactly one module.** `JMAP::API::*` all declare
`package JMAP::API`, so two files defining the same sub is legal Perl — the last
`require` in `JMAP/API.pm` silently wins. That had already happened twice (a stub
`Quota/get` in `Preferences.pm` returning `used => 1, total => 2`, and a
`Principal/get` in `Calendar.pm`), and only a redefinition warning gave it away.
`grep -h '^sub api_' JMAP/API/*.pm | sort | uniq -d` must stay empty.

## Specs

Normative sources are checked into `specs/` (RFCs 8620/8621, 9553–9555, 9610, the
jscalendarbis/jscontact/jmap-calendars drafts, etc.). Check compliance against these
files rather than from memory; `ROADMAP.md` tracks per-feature status.

## Deployment

Built and shipped as a Docker image (`ghcr.io/jmapio/jmap-proxy`); the proxy speaks
plain HTTP behind a TLS-terminating reverse proxy. `BASEURL` must be set or OAuth
redirect URIs default to localhost. See SETUP.md (Docker, env vars, OAuth2 provider
registration, AES-256-GCM vs OpenBao credential encryption) and API.md (management API).
