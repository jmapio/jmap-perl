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
- `JMAP/API.pm` — JMAP request handler; dispatches to per-datatype method modules in
  `JMAP/API/` (`Email`, `Mailbox`, `Thread`, `Calendar`, `Contact`, `Submission`,
  `StorageNode`, `MDN`, `Quota`, `Preferences`).
- `JMAP/Sync/` — backend sync drivers (`Standard`, `Gmail`, `Fastmail`, `AOL`, `Common`).
- `JMAP/OAuth/` — OAuth2 signup (`Google`, `Fastmail`, `OIDC`, `PACC`, `PKCE`).
- `JMAP/CredentialStore.pm` — pluggable at-rest encryption for stored credentials.

## Data model

- `accounts.sqlite3` — global: which accounts exist, type, tokens, auth, pool grouping (`poolid`).
- one `<accountid>.sqlite3` per account — all synced mail/calendar/contact state plus
  the `iserver` table (backend connection config, including auto-detected `imapSep`).
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
```

Debugging: set `JMAP_DEBUG=1` to log full request/response bodies. Proxy stderr goes
to `/tmp/jmap-proxy.log` when started via `restart-test-proxy.sh`.

Test-account hygiene: `any_account` reuses `user1` and accumulates state across runs —
use `pristine_account` for tests that create named resources (mailboxes, calendars,
addressbooks). `pool_account_pair` creates two pristine accounts in one pool for
cross-account `/copy` tests.

## Specs

Normative sources are checked into `specs/` (RFCs 8620/8621, 9553–9555, 9610, the
jscalendarbis/jscontact/jmap-calendars drafts, etc.). Check compliance against these
files rather than from memory; `ROADMAP.md` tracks per-feature status.

## Deployment

Built and shipped as a Docker image (`ghcr.io/jmapio/jmap-proxy`); the proxy speaks
plain HTTP behind a TLS-terminating reverse proxy. `BASEURL` must be set or OAuth
redirect URIs default to localhost. See SETUP.md (Docker, env vars, OAuth2 provider
registration, AES-256-GCM vs OpenBao credential encryption) and API.md (management API).
