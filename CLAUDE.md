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
- **Held EmailSubmissions (FUTURERELEASE) are sent by the worker, scheduled by the parent.**
  `create_submissions` keeps a Bcc-stripped copy in the account's `outbox/` and marks the row
  `undoStatus = 'pending'`; the worker then reports `['sendat', $epoch]` asynchronously, the
  parent's `schedule_send` stores it in `accounts.nextsend` (schema v3) and arms a timer that
  sends the worker `send_due`, which delivers what is due and answers the next time. Startup
  re-arms from `accounts.nextsend`. Destroying a submission must not cancel its delivery
  (RFC 8621 S7.5), so `send_due` ignores `active`; only `undoStatus: canceled` stops it.
- **`accounts.sqlite3` has one writer, `__accounts__`.** The parent never opens it (it
  pings `__accounts__` at startup, which migrates it); an account worker opens it read-only
  for its own row. A signup is probe (a `"<fresh id>:signup"` worker, which stores nothing),
  then `claim_account` (`JMAP::AccountClaim`: new, or an existing account the caller proved
  it owns), then `setup` **in the claimed account's own worker** (`_claim_and_setup`). Setting
  up in the probing worker wrote a re-bound account's credentials to an orphan file
  (`t/account-rebind.t`). **A settings change restarts both of the account's workers**
  (`_restart_account`): the backfill worker is stopped at once and its loop restarted under
  the new login. Dropping only the main worker left the backfill fetching through the old
  login, fighting the new one over INBOX (`t/account-rebind-backfill.t`).
- **Never call `get_user()` outside a transaction** — Perl autovivification of
  `$Self->{t}{user}` leaves a phantom `$Self->{t}={}` and corrupts later transaction state.
  Cache values you need inside the transaction for use in closures.

## Code layout

- `bin/jmap-proxy.pl` — the server (parent + worker loop + cross-account `/copy` orchestration).
- `JMAP/DB.pm` — base DB class (SQLite schema, transactions, sync state, query snapshot cache).
  - `JMAP/ImapDB.pm` (← DB) — IMAP/CalDAV/CardDAV/WebDAV sync, including the FileNode mirror,
    its writes and `shareWith` (`set_filenode_sharewith` and its propagation).
    `FastmailDB` and `GmailDB` extend it.
  - `JMAP/JmapDB.pm` — standalone, for JMAP passthrough backends.
- `JMAP/Dispatch.pm` — pure, unit-testable dispatch core: the method → capability table,
  `check_accounts` (a missing
  `accountId` is `invalidArguments`, one outside the session is `accountNotFound` — the
  proxy never defaults it), `group_batches` (order-preserving same-upstream batching) and
  `resolve_pointer` (JSON Pointer with JMAP `*` semantics).
  No I/O, no DB — keep it that way; `t/dispatch-*.t` covers it.
- `JMAP/AccountClaim.pm` — which account a signup lands on, run by `__accounts__` in one
  transaction: the bind rules, `JMAP_DISABLE_SIGNUP`, a taken id. Pure apart from the `$dbh`;
  `t/account-claim.t`.
- `JMAP/Collation.pm` — the sort collations (`i;octet`, `i;ascii-casemap`, and the default
  `i;unicode-casemap`) advertised in `collationAlgorithms`. Every string comparator in a
  `/query` sort goes through `JMAP::Collation::compare` with the Comparator's `collation`;
  a bare `cmp` there ignores it. Pure, like `Dispatch`; `t/collation.t` covers it.
- `JMAP/QueryChanges.pm` — the `removed`/`added` lists of a `/queryChanges` from the old
  snapshot, the new results and the set of results that may have changed; also reports
  ids that moved without changing (the fewest: those outside the longest run that kept its
  order). Email, Mailbox, CalendarEvent and ContactCard use it. Pure; `t/query-changes.t`.
- `JMAP/EventSpan.pm` — each event's span (`jevents.firststart`/`lastend`, naive epochs,
  schema v17) and the widened SQL prefilter range queries use; the exact check still runs on
  what passes. Pure; `t/event-span.t` requires the same answers with spans and without.
- `JMAP/FileNode.pm` — pure FileNode logic: ids, blob ids, name rules, globs, rights,
  reconciliation, `/set` ordering, filters and sorts. No I/O, no DB; `t/filenode-*.t`.
- `JMAP/Sync/WebDAVTalk.pm` — a `Net::DAVTalk` subclass for FileNode: PROPFIND normalised to
  entries, PUT/MKCOL/MOVE/COPY/DELETE/PROPPATCH, RFC 3744 ACLs, RFC 4331 quota, and `Probe`
  (what the server really does). Protocol only, no DB.
- `JMAP/FileNodeCopy.pm` — cross-account `FileNode/copy`, run in the parent: every request
  goes through an injected `send` (the proxy's `send_backend_request`), so it never blocks and
  `t/filenode-copy.t` drives it against a fake. Pages the source listing, stages a directory
  copy under a temporary name when `onExists` would replace, rolls back by explicit ids.
- `JMAP/API.pm` — JMAP request handler; dispatches to per-datatype method modules in
  `JMAP/API/` (`Email`, `Mailbox`, `Thread`, `Calendar`, `Contact`, `Submission`,
  `FileNode`, `Principal`, `MDN`, `Quota`, `Preferences`, `Blob`). `JMAP/API/FileNode.pm` serves
  every `FileNode/*` method from the mirror (`FileNode/copy` is cross-account only, in
  `FileNodeCopy`). `JMAP/BlobConvert.pm` is the pure
  engine behind the blob extensions (RFC 9404 and the blobext draft): UTF-8 checks, digests,
  archive/compress/delta/image recipes, with runtime detection of the optional modules.
- `JMAP/Sync/` — backend sync drivers (`Standard`, `Gmail`, `Fastmail`, `Common`).
- `JMAP/OAuth/` — OAuth2 signup (`Google`, `Fastmail`, `OIDC`, `PACC`, `PKCE`).
- `JMAP/CredentialStore.pm` — pluggable at-rest encryption for stored credentials.

## FileNode over WebDAV

Design: `docs/superpowers/specs/2026-10-09-filenode-webdav-design.md`. Files live on the
account's WebDAV server (`iserver.webdavURL`; on Cyrus, `#drive`), and `jfilenodes` mirrors
their **metadata only**: every method reads the mirror, every write goes to WebDAV first.

- **Ids say where they come from**: `S` + hash of the server's stable id (survives any move),
  `L` + uuid when the server has none (survives the proxy's moves; another client's move is
  matched by fingerprint where one survives the MOVE -- not on Cyrus, which resets the ETag
  and both timestamps, so there it is a destroy plus a create). A sync never reissues an id
  it already holds.
- **Sync cadence**: one PROPFIND per collection, so not every tick — 60 s on demand from a
  FileNode method, 300 s from the periodic `sync`, first walk in the backfill worker. Never
  prune a subtree on an unchanged collection ETag: Cyrus does not propagate them upwards.
  Nor is RFC 6578 sync-collection a way out on Cyrus: it refuses `sync-level: infinite`, and
  a collection's sync report lists new files but not new subcollections (checked 2026-11-08).
- **Server values go in columns, client values in dead props** under
  `https://jmap.io/ns/filenode` (R4). Dead-prop support is learnt by reading one back:
  Cyrus answers a file's PROPPATCH 200 and stores nothing.
- **Trust nothing the server says about itself.** `Probe` tries each feature and keeps the
  result in `iserver.webdavFeatures` (`deadProps`, `etagIsContent`, `acl`, `quota`, ...);
  other facts are learnt on first use (`moveLeavesEmpty`, `principalBase`, `privileges`).
  An account probed before a key existed lacks it, so code must treat a missing key as
  "unknown", not "no". Nor its status codes: a PUT is checked against the size the server
  then lists — so a server that alters bytes on PUT (line-ending normalisation, transcoding)
  is refused outright. A server without WebDAV at `webdavURL` fails the Probe, and FileNode
  is advertised only once a Probe has worked (`JMAP::Capabilities::filenode_ok`). Each defence replays a canned bad answer (`t/webdavtalk-canned.t`,
  `t/filenode-set.t`).
- **`FileNode/set` is judged by its final state**: destroys, creates and moves are ordered
  (temporary names break swaps and cycles) so sibling names stay unique at every step. A
  node the client asked to move or rename is **never deleted by the same call** — not by a
  destroy, a `replace`, or `onDestroyRemoveChildren` — even when that move is refused.
- **`shareWith` is a directory's own entries (draft -20); its WebDAV ACL is their union with
  everything above.** Inherited rights are a floor. Cyrus ACLs do not inherit, so the proxy keeps
  each directory's own entries (`jfilenodes.ownshare`; derived from the ACL as what exceeds the
  parent's where it never stored one) and writes each ACL as own + parent's, top-down, after a
  change or a move. The `sharewith` column is the ACL's users (effective), not `shareWith`. Files are never shared (an ACL
  on a Cyrus file rewrites its collection's). Cyrus lists ACEs (e.g. `defaultacl`'s
  `admin`) that it then refuses back; the proxy fails the share rather than drop one,
  unless it is named in `JMAP_FILES_DROPPABLE_PRINCIPALS` (the test stack sets `admin`).
- **Test stack**: `restart-test-proxy.sh clean` builds and runs `<CYRUS_IMAGE>-webdav`, a
  derived image with `webdav` in `httpmodules`; `docker restart` of the Cyrus container
  breaks its auth, so recreate it with `clean` instead. Cyrus has no FileNode, so
  `t/FileNode/` has no `--direct` baseline: every failure there is the proxy's — except
  `t/FileNode/set/zero-byte.t`, which fails because Cyrus cannot store an empty file (a
  zero-length PUT stores the previous request's body; the proxy answers `serverFail`).

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
- **A CalendarEvent id is not its UID.** `jevents` is keyed by the iCalendar UID, which
  can be any string (`abc@example.com`), but an Id may only use `A-Za-z0-9-_` (RFC 8620
  S1.2). `JMAP::EventId` maps a UID to its id (unchanged when it already is a valid Id,
  else `_h` + sha256) and an instance to `_r<YYYYMMDD[THHMMSS]>_<event id>`; the API
  layer converts at its edges (`_event_id_resolver` going in), while ImapDB, the
  `jqueries` snapshots and `/set` keys handed to ImapDB keep UIDs.
- **One CalendarEvent per UID, in every calendar holding a copy.** CalDAV lets a UID be in
  several calendars; each copy is an `ievents` row, and the event's `calendarIds` is the set
  of calendars with one (`jevents.jcalendarids`, schema v15). A copy that goes (its resource,
  or its calendar) takes only its calendar out of `calendarIds`; the last copy takes the event.
  An update goes to every copy, a calendar added to `calendarIds` gets a WebDAV COPY, one
  removed loses its copy, and a destroy deletes them all. ContactCards work the same way with
  `icards` copies and `addressBookIds` (`jcontacts.jaddressbookids`, schema v16). Account ids must be
  valid Ids too: `POST /api/accounts` refuses any other.
- **CalDAV/CardDAV hrefs are unescaped**, in `ievents`/`icalendars`/`icards`/`iaddressbooks`
  (schema v18 unescaped the CardDAV ones). That is the Net::\*DAVTalk rule (Net::DAVTalk 0.26,
  Net::CalDAVTalk 0.19, Net::CardDAVTalk 0.14): every href they return is unescaped and every
  path they take is escaped by them, in URLs and request bodies alike. Servers spell one href
  differently (Google's CardDAV writes `@` in a PROPFIND, its CalDAV `%40`), so compare hrefs
  only in that form; one compared raw is a card "removed and created" on every sync.
- **A DAV collection with no usable sync token** is synced from nothing by
  `ImapDB::_dav_links_from_nothing`: a token-less sync-collection where the server allows it,
  else a PROPFIND listing plus the collection's `DAV:sync-token`. Google refuses the
  token-less REPORT (400) and pages every sync (a 507 on the collection, RFC 6578 S3.6, which
  `SyncCollection` follows). Neither shows on Cyrus, so `t/dav-collection-sync.t` fakes them.

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
`t/AddressBook/changes` and `t/Calendar/changes` used to look flaky: they failed on the
first run after a `clean` and passed on every rerun. That was a real bug — `firstsync`
never synced DAV, so a fresh account's pre-existing collections first appeared in
`/changes` as created. A failure that only happens on a fresh account is a bug, not a flake.

`run-jmap-tests.sh` with no arguments runs **all of `t/`**. It used to run a hand-picked
directory list, which silently skipped `t/core/`, `t/Blob/` and the top-level `t/*.t` for
months and hid five real proxy bugs (ResultReference validation, dropped error responses,
Blob/copy arguments, downloadUrl `{type}`, unknown-mailbox moves). Never narrow it again.

On the suite's `spec-correctness` branch (296 files, 2026-11-07, image
`cyrus-test-server:suite-fixes-20261002b`) IMAP mode fails **0 against the proxy and 59
`--direct`**. Every failure along the way was judged against the spec, which decides whether
the proxy or the test is wrong ("Cyrus fails it too" decides nothing: in IMAP mode the
proxy answers every method itself).
Email ids (`ImapDB::_msgid_for`): the server's RFC 8474 EMAILID/THREADID where it has
OBJECTID, Gmail's X-GM-MSGID, else a hash of the ENVELOPE and RFC822.SIZE (the envelope
alone gave a self-delivered copy the sent copy's id). Schema v14 re-keys existing folders
on their next sync (`rekey_folder`); clients see a changed id as destroyed plus created.
The test image is derived with `munge8bit: no` (Cyrus's default rewrites 8-bit header
bytes to `X`, so EAI mail, RFC 8621 S4.8, could never be stored). The test stack
registers `user1@example.com` (the image's users are in example.com) and sends through the image's Postfix on 8587 (AUTH PLAIN, no TLS); suite logins are the
account's email. The run needs Text::JSCalendar 0.10, Text::JSContact 0.06 and
Data::JSEmail 0.06 (on CPAN since 2026-11-07; earlier versions predate the proxy's switch to
their codecs. To test against module checkouts instead, prepend their `lib` dirs to `PERL5LIB`,
so local::lib stays, both for the restart and for the run).

**Every `api_*` method lives in exactly one module.** `JMAP::API::*` all declare
`package JMAP::API`, so two files defining the same sub is legal Perl — the last
`require` in `JMAP/API.pm` silently wins. That had already happened twice (a stub
`Quota/get` in `Preferences.pm` returning `used => 1, total => 2`, and a
`Principal/get` in `Calendar.pm`), and only a redefinition warning gave it away.
`grep -h '^sub api_' JMAP/API/*.pm | sort | uniq -d` must stay empty.

**Every method is labelled with the capability that selects it.** `JMAP::Dispatch`
holds the method → capability table (`method_capabilities`,
`method_capability_missing`); `handle_request` answers `unknownMethod` for a
method whose capability the request's `using` does not list, so a request can
be filtered before anything in it runs. Adding an `api_*` sub means adding it
to the table under the specification that defines it (RFC 8621 puts
`Identity/*` under `submission`, RFC 9404 puts `Blob/copy` under `core`, the
blobext draft lets `Blob/get` and `Blob/lookup` run under `blob` or `blob2`).
`t/dispatch-method-capability.t` fails on any method left out.

## Specs

Normative sources are checked into `specs/` (RFCs 8620/8621, 9553–9555, 9610, 9982, 10050,
the jscalendarbis/jscalendar-icalendar/jmap-calendars drafts, etc.), each draft at its latest
revision (checked with the ietf-llm `draft_status` tool; last refreshed 2026-11-07). Check compliance against these
files rather than from memory; `ROADMAP.md` tracks per-feature status.

## Deployment

Built and shipped as a Docker image (`ghcr.io/jmapio/jmap-proxy`); the proxy speaks
plain HTTP behind a TLS-terminating reverse proxy. `BASEURL` must be set or OAuth
redirect URIs default to localhost. See SETUP.md (Docker, env vars, OAuth2 provider
registration, AES-256-GCM vs OpenBao credential encryption) and API.md (management API).
