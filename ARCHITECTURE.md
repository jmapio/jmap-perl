# JMAP Proxy Architecture

How the server is put together: processes, how they talk, and what runs where.
Deployment and configuration (TLS, OAuth registration, credential encryption,
environment variables) are in SETUP.md; the management API is in API.md.

## Process model

`bin/jmap-proxy.pl` is one program. The parent runs an `EV`/`AnyEvent` event loop
and forks blocking workers, one per name, each over a Unix socketpair.

```
PARENT (event loop -- NEVER BLOCKS)
  |-- AnyEvent::HTTPD on JMAP_PORT       public: JMAP, EventSource, signup UI, OIDC
  |-- AnyEvent::HTTPD on JMAP_MGMT_PORT  /api (management), /healthz, /metrics
  |-- %backend  name -> [handle, cmd_counter, pid, last_active, last_heard]
  |-- %waiting  name -> { "#n" -> [success_cb, error_cb, background] }
  |-- timers    sync, idle reaper, stuck-worker killer, push refresh,
  |             token-touch flush, held-send timers, startup resume
  \-- SIGCHLD reaper, SIGTERM/SIGINT drain

WORKER "__accounts__"            accounts.sqlite3: accounts, tokens, pools,
                                 push subscriptions, needs_backfill, nextsend
WORKER "<accountid>"             the account's JMAP methods and sync
WORKER "<accountid>:backfill"    the same account's backfill (separate process)
```

Workers are forked on first use by `get_backend($name)` and loaded lazily: an
account worker installs `JMAP::NetGuard` (no connections to private addresses
unless the operator allows them) and only then requires `JMAP::API`/`JMAP::ImapDB`.
`run_backend_worker` strips a trailing `:[^:]+$` from the name, so `:backfill`
shares the account's database but never its process.

### Wire protocol

Each message is one JSON array, newline-terminated, in both directions.

- Parent to worker: `[command, args, "#n"]` (`send_backend_request`). `#n` is a
  per-worker counter, and the callbacks wait in `%waiting{name}{"#n"}`.
- Worker reply: `[result_name, value, "#n"]`, or `['error', message, "#n"]`.
- Worker notices, untagged, at any time (handled in `mk_json`):
  - `['push', {type => state}]`: data changed; fan out to EventSource and push.
  - `['synced', time]`: last successful sync (for `/metrics` and the UI).
  - `['needsbackfill', time]`: sync found folders to backfill; start `prod_backfill`.
  - `['sendat', epoch|null]`: next held EmailSubmission due time; `schedule_send`.

### Error semantics

- An **account worker** that fails a command answers `error` and exits. The parent
  drops the handle and fails every other request queued on it (`_fail_pending`).
  The next request forks a fresh worker.
- The **`__accounts__` worker** answers `error` and keeps going
  (`JMAP::Workers::survives_error`).
- A worker that disappears (EOF, handle error, killed) has all its pending
  requests failed. Each pending entry is an HTTP connection parked on
  `respond()`, and leaking one leaks a file descriptor.

## Who owns what

| Process | Owns | Never |
|---|---|---|
| Parent | HTTP routing, auth caches, session state, EventSource connections, outbound push POSTs, `/copy` orchestration across upstreams, timers | blocking I/O of any kind: IMAP/DAV, `DBI`, `JMAP::ImapDB->new`, `setuser`, `firstsync`, `sync_*` |
| `__accounts__` | `accounts.sqlite3`, its only writer: account rows (which account a signup lands on, `claim_account`), tokens, pools, push subscriptions, `needs_backfill`, `nextsend`, `cred_fingerprint`. It also reads per-account DBs for login checks (`auth`, `verify_credentials` read the `jserver`/`iserver` row) and stats | IMAP/DAV connections |
| `<accountid>` | the account's `<accountid>.sqlite3`, every backend connection (IMAP, SMTP, CalDAV, CardDAV, WebDAV, upstream JMAP), all JMAP method handling, periodic sync, sending held submissions | backfill |
| `<accountid>:backfill` | backfill of older mail; the account's first FileNode walk | JMAP methods, sync |
| `<fresh id>:signup` | one signup probe: autodiscovery and a login, or fetching an upstream Session; then dropped | any database: a passthrough probe's `JmapDB` is in memory |

The parent never opens `accounts.sqlite3`: at startup it pings `__accounts__`,
which migrates the file before it reads its first command. An account worker
opens it read-only, for its own `email`/`type`.

## Account worker commands

`run_backend_worker` dispatches these commands:

| Command | What it does |
|---|---|
| `jmap` | One batch of method calls: `JMAP::API->handle_request`, or `JmapDB->handle_jmap` for passthrough. May emit `sendat`. |
| `sync` | `sync_folders`, `sync_imap`, CalDAV/CardDAV (`_dav_sync_safely`: a broken DAV server must not take mail down), and a FileNode walk at most every 300 s (always with `force`). Emits `needsbackfill` and `synced`. No-op for passthrough. |
| `backfill` | Sent only to `:backfill` workers. Runs the first FileNode walk, then one `backfill()` step; answers whether more remains. |
| `davsync` | CalDAV/CardDAV only. |
| `send_due` | Delivers held submissions now due; answers the next due time. |
| `upload`, `download`, `raw`, `filenode_put` | Blob I/O (FileNode content goes straight to WebDAV). |
| `fetch_blobs`, `store_blob` | Blob transfer for parent-orchestrated cross-account `/copy`. |
| `session_caps` | Passthrough: this account's slice of the upstream Session. |
| `signup`, `signup_jmap` | Probes, in a `:signup` worker: verify the credentials and answer the resolved settings. They store nothing. |
| `setup` | `setuser` and `firstsync` (plus `sync_imap` unless `skip_sync`); passthrough: store the probed settings and answer the `cred_fingerprint`. |
| `get_settings`, `update_settings` | Backend connection settings (verified by logging in first; a passthrough login's new fingerprint goes back to the parent). |
| `pdpa_export`, `pdpa_import` | Whole-account export/import (`JMAP::PDPA`). |
| `delete` | Drop the account's data; the worker exits. |
| `ping`, `getinfo` | Liveness; `[email, type]`. |

The `__accounts__` commands (`auth`, `resolve_token`, `get_pool`, `create_account`,
`push_*`, `*_backfill`, `*_nextsend`, ...) are in `run_accounts_worker`.

## Inside an account worker

```
jmap-proxy.pl worker loop
  \-- JMAP::API  (JMAP/API/*.pm: one package, one file per datatype)
        |-- JMAP::Dispatch      capability check, accountId check (pure)
        |-- JMAP::QueryChanges, JMAP::Collation, JMAP::EventSpan, JMAP::FileNode (pure)
        \-- JMAP::ImapDB  (<- JMAP::DB: schema, transactions, change states)
              |-- JMAP::GmailDB, JMAP::FastmailDB      provider subclasses
              |-- JMAP::Sync::{Standard,Gmail,Fastmail} (<- Sync::Common)  IMAP + SMTP
              |-- JMAP::Sync::CalDAVTalk, Net::CardDAVTalk                  DAV
              \-- JMAP::Sync::WebDAVTalk                                    FileNode
JMAP::JmapDB   passthrough accounts: no JMAP::API, requests rewritten and forwarded
```

The account type (`imap`, `gmail`, `fastmail`, `jmap`) in `accounts.sqlite3`
picks the DB class. Email, calendar and contact conversion is done by
`Data::JSEmail`, `Text::JSCalendar` and `Text::JSContact`, which are separate
CPAN modules. A DB change calls `change_cb`, which writes the `push` notice to
the parent.

## Request flows

### A JMAP request (`POST /jmap`)

1. `_authenticate` checks the Bearer token, session cookie or Basic auth,
   asking `__accounts__` (`resolve_token`, `auth`) and caching the answer.
2. `get_pool_cached` fetches every account the login can see, with type,
   `backendAccountId` and `cred_fingerprint`.
3. `JMAP::Dispatch::group_batches` splits the method calls into
   order-preserving batches by **upstream key**:
   - `fp:<cred_fingerprint>` for passthrough accounts, so accounts sharing an
     upstream login share a batch;
   - `imap:<accountid>` for everything else.
4. The batches run strictly in order. Each one is a `jmap` command to its
   worker. The parent threads `createdIds` through and resolves
   ResultReferences between batches itself.
5. A `/copy` between two different upstreams is orchestrated in the parent
   (`_do_copy_call`: `fetch_blobs` from one worker, `store_blob` plus `/set` on
   the other), and so is cross-account `FileNode/copy` (`JMAP::FileNodeCopy`).
   Neither ever blocks.

CLAUDE.md lists the rules for this path ("Passthrough request dispatch").

### Sync and backfill

- Every `JMAP_SYNC_INTERVAL` seconds (default 30), the parent sends `sync` to
  each live account worker that has nothing queued. `sync` counts as background
  work, so it does not keep an idle worker alive.
- Backfill runs in `<accountid>:backfill`, driven by `prod_backfill`: one
  `backfill` step, a 10 s pause, repeated until it answers "done", and then
  `clear_backfill`. It starts in three ways:
  - at signup;
  - on a `needsbackfill` notice from sync;
  - at startup, for accounts still flagged `needs_backfill`.

### Held submissions (FUTURERELEASE)

1. `EmailSubmission/set` keeps a Bcc-stripped copy in the account's `outbox/`.
2. The worker emits `sendat`. `schedule_send` stores it in `accounts.nextsend`
   and arms a timer.
3. When the timer fires, the parent sends `send_due`, which delivers whatever
   is due and answers with the next time.
4. If a send fails, it is retried in a minute.
5. At startup, the timers are re-armed from `get_nextsends`.

### Push

- **EventSource** (`/eventsource`): the connections live in the parent
  (`%PushMap`), and `push` notices go straight to them.
- **PushSubscription**: stored by `__accounts__`. The parent verifies each one
  and POSTs StateChanges to it, with backoff per subscription. Every 60 s,
  `_push_refresh` asks which accounts have a verified subscription and spawns
  workers for any that are not running.
- An account with an EventSource client or a verified subscription keeps its
  worker alive, so that its changes are still noticed.

### Account creation

Every route but one has the same three steps, driven by the parent
(`_claim_and_setup`):

1. **Probe**, in a worker of its own (`<fresh id>:signup`): `signup` (DNS SRV
   discovery and an IMAP login) or `signup_jmap` (fetch the upstream Session,
   resolve `backendAccountId` and the URLs). It stores nothing.
2. **Claim**, in `__accounts__` (`claim_account`, `JMAP::AccountClaim`), in one
   transaction:
   - an email with no account gets a new one under the fresh id, unless
     `JMAP_DISABLE_SIGNUP` closes signup;
   - an email that has one lands on it only if the caller proved it owns it:
     the management API (an admin), an OAuth provider vouching for the
     address, or Fastmail's session naming the login;
   - otherwise the claim is refused, and the owner logs in instead
     (`verify_credentials`).
3. **Setup**, in the claimed account's own worker: `setuser` and `firstsync`.
   A re-bound account's worker is restarted first. A failed setup removes an
   account the claim made, and leaves one that was there before.

Doing setup anywhere else is the bug this order prevents: a probing worker
that stored the credentials put a re-bound account's new login in a file
nothing reads (`t/account-rebind.t`).

The routes:

- **Signup form** (`/discover`, then `/signup`): probe, claim, setup. Then the
  parent sends `sync`, starts the backfill and issues a session token. With
  signup closed, an address with no account is refused before the probe.
- **OAuth** (`/cb/oauth`): the parent exchanges the code; there is no probe
  (the provider checked the login), so it goes straight to claim and setup.
- **Passthrough** (`/signup_jmap`, Fastmail over OAuth, and the management API
  with a `sessionUrl`): probe with `signup_jmap`, claim, setup, then
  `set_cred_fingerprint`.
- **Management API**, IMAP: the exception. `create_account` (keyed by the
  accountid the admin chose), then `setup`; the API answers 201 once the mail
  has synced.

Discovery order for an address at `/discover`:

1. Gmail: Google OAuth, if `GOOGLE_CLIENT_ID`/`SECRET` are set.
2. Fastmail: a choice between JMAP passthrough and IMAP over OAuth.
3. PACC (`ua-auto-config.<domain>`):
   - `protocols.jmap.url` gives a passthrough signup;
   - `oauth-public.issuer` gives RFC 8414 OAuth;
   - otherwise its IMAP/SMTP settings pre-fill the form.
4. Mozilla autoconfig: pre-fills the form.
5. A plain password form, with SRV lookup in the worker.

The proxy is also an OpenID Connect provider (`/oauth/*`, `JMAP::OAuth::OIDC`)
for clients that sign in to it.

## Lifecycle

- **Startup**: start `__accounts__`, which migrates `accounts.sqlite3`. After
  5 s, resume pending backfills and re-arm held-send timers.
- **Idle reaper** (every 60 s): closes account workers idle for longer than
  `JMAP_IDLE_TIMEOUT` (default 300; 0 disables it). `__accounts__` is never
  closed, and neither is a worker that is busy, backfilling, or has push
  listeners (`JMAP::Workers::reapable`). Once the parent drops the handle, the
  worker sees EOF and exits.
- **Stuck workers** (every 60 s): a worker with requests queued that has not
  answered for `JMAP_WORKER_TIMEOUT` seconds (default 1800) gets SIGTERM, and
  its requests are failed.
- **Token touches**: last-used time and IP are kept in memory and written to
  `__accounts__` every 300 s.
- **Shutdown** (SIGTERM/SIGINT):
  1. Both ports answer 503 to new requests.
  2. In-flight requests drain.
  3. Token touches are flushed.
  4. The parent exits.
- **Health**: `/healthz` and `/metrics` (Prometheus counters from `%stat`) on the
  management port.

## Storage

- `$JMAP_DATADIR/accounts.sqlite3`: global (schema versioned in
  `_migrate_accounts_db`).
- `$JMAP_DATADIR/<accountid>.sqlite3`: one per account (schema versioned in
  `JMAP::DB`).
  - An IMAP-family account's file has an `iserver` row (backend settings,
    detected `imapSep`, `webdavFeatures`) plus the synced mail, calendar,
    contact and FileNode mirror.
  - A passthrough account's file has a single `jserver` row.
- `$JMAP_DATADIR/oidc_key.pem`: the OIDC signing key.
- Credentials at rest go through `JMAP::CredentialStore` (SETUP.md,
  "Credential Encryption").

## Docker

`bin/docker-entrypoint.sh` creates `/data`, raises the file descriptor limit,
hands `/data` to the unprivileged `jmap` user and runs `jmap-proxy.pl` as that
user; the whole server is that one process tree. The image exposes `JMAP_PORT` (public) and
`JMAP_MGMT_PORT` (bound to localhost unless `JMAP_MGMT_HOST` says otherwise),
and keeps all state in the `/data` volume.
