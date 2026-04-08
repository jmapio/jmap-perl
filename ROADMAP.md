# JMAP Proxy Roadmap

## Current State (April 2026)

The JMAP proxy syncs email, calendars, and contacts from IMAP/CalDAV/CardDAV
backends and exposes them over the JMAP protocol (RFCs 8620/8621).

- **81/81 JMAP TestSuite tests passing** against Cyrus IMAP
- Conversion logic extracted into standalone CPAN modules:
  Data::JSEmail (0.03), Text::JSCalendar (0.03), Text::JSContact (0.01)
- Docker image with single-process architecture and management UI
- Per-account SQLite databases, forked workers per account

## Phase 1: Docker & Deployment ✅

### Architecture
```
┌──────────────────────────────────┐
│ Docker container                  │
│                                   │
│  jmap-proxy.pl (parent process)   │
│    ├─ :$JMAP_PORT  AnyEvent HTTP  │
│    ├─ :$MGMT_PORT  Management UI  │
│    └─ fork per account            │
│         └─ blocking JSON worker   │
│              └─ SQLite + IMAP     │
│                                   │
│  Volume: /data                    │
│    └─ accounts.sqlite3            │
│    └─ per-account .sqlite3 files  │
└──────────────────────────────────┘
```

### Environment Variables
- `JMAP_PORT` — external JMAP endpoint (default 9000)
- `JMAP_MGMT_PORT` — management UI (default 8080)
- `JMAP_MGMT_HOST` — management bind address (default 127.0.0.1, 0.0.0.0 in Docker)
- `JMAP_DATADIR` — data directory (default /data)
- `BASEURL` — public URL for the proxy

### Done
- [x] Single-process server (bin/jmap-proxy.pl)
- [x] Non-blocking parent (AnyEvent HTTP), blocking forked children per account
- [x] Children: simple JSON read/process/write loop, no event loop
- [x] Children die on error for clean state restart
- [x] Dockerfile with all CPAN dependencies (Debian bookworm-slim)
- [x] docker-entrypoint.sh with accounts DB init
- [x] Management REST API (account CRUD, sync triggers, stats)
- [x] HTML dashboard (self-contained, no template files)

### Still TODO
- [x] Health check endpoint (`GET /healthz` on mgmt port)
- [x] Graceful shutdown (SIGTERM/SIGINT: stop accepting, close children, exit)
- [x] TLS termination documentation (nginx/Caddy examples in ARCHITECTURE.md)
- [x] Idle timeout for backend children (`JMAP_IDLE_TIMEOUT`, default 300s)

### Database: SQLite stays
Per-account SQLite files are the right model: zero contention between
accounts, no external service dependency, backup is copying files, and
the proxy is bottlenecked on IMAP not the database.  If we ever need
shared state (e.g. push notification routing), that can be a single
small shared DB.

## Phase 2: Multiple Backends Per User

A user can have multiple backends.  Each backend is a separate JMAP
account — the JMAP Session object lists all accounts the user has
access to, and the client addresses each one by accountId.

This is how JMAP is designed to work: the Session response advertises
multiple accounts with their capabilities, and the client picks which
accountId to use for each method call.  No mailbox merging, no ID
namespacing, no cross-account thread complexity.

### Data Model
```
user (auth identity)
  └─ accounts[]
       ├─ accountId (unique, maps to a single backend)
       ├─ type: imap | jmap | gmail
       ├─ name: "Work", "Personal", etc.
       ├─ host, port, credentials
       ├─ capabilities: mail, calendars, contacts
       └─ sync state (own .sqlite3 file)
```

### Session Response
```json
{
  "accounts": {
    "acc-work":     { "name": "Work (Cyrus)",    "isPersonal": true  },
    "acc-personal": { "name": "Personal (Gmail)", "isPersonal": false },
    "acc-shared":   { "name": "Team Mailbox",     "isReadOnly": true  }
  },
  "primaryAccounts": {
    "urn:ietf:params:jmap:mail": "acc-work",
    "urn:ietf:params:jmap:calendars": "acc-personal"
  }
}
```

### Tasks
- [ ] User → accounts mapping (one user authenticates, sees N accounts)
- [ ] Per-account backend configuration
- [ ] Session response with multiple accounts and capabilities
- [ ] Management UI: add/remove backends for a user
- [ ] Independent sync scheduling per account

## Phase 3: JMAP Backend Passthrough

When a backend already speaks JMAP (Cyrus, Fastmail, etc.), the proxy
should pass requests through directly instead of syncing via IMAP.

```
Client ──JMAP──▶ Proxy ──JMAP──▶ Cyrus (passthrough, acc-work)
                   │
                   └──IMAP──▶ Dovecot (sync, acc-personal)
```

### What passthrough does
- Forward method calls to the backend, rewriting accountId
- Proxy blob upload/download
- Relay push notifications
- No local sync state needed — the backend is the source of truth

### What the proxy still provides
- **Single auth**: user authenticates once, proxy holds per-backend credentials
- **Unified Session**: one Session lists all accounts regardless of backend type
- **Protocol bridging**: legacy IMAP backends and native JMAP backends
  appear the same to the client

### Incremental approach
1. Read-only passthrough (get/query methods)
2. Write passthrough (set methods)
3. Blob proxying
4. Push relay

### Tasks
- [ ] JMAP client module (HTTP::Tiny + JSON, or LWP)
- [ ] JmapDB.pm backend type (parallel to ImapDB.pm)
- [ ] Request routing by accountId → backend type
- [ ] Blob upload/download proxying
- [ ] Push subscription relay

## Phase 4: Polish & Production Readiness

### Auth
- [ ] OAuth2 / OpenID Connect support
- [ ] Per-backend credential storage (encrypted at rest)
- [ ] Session management with proper token lifecycle

### Performance
Much of the performance work is already done:
- Connection reuse: persistent forked child per account holds
  IMAP/CalDAV/CardDAV connections open across requests, with
  separate connections for sync vs interactive operations
- Lazy body fetching: sync only fetches envelope/flags/size;
  full RFC822 bodies are fetched on demand via `fill_messages`
  and cached in `jrawmessage`

- [ ] Incremental sync scheduling (CONDSTORE/QRESYNC already used)
- [ ] Query result caching for proper queryChanges with filters
- [ ] Move parsed message cache out of SQLite (`jrawmessage`) into
  per-account file directories (e.g. `/data/{accountid}/cache/{msgid}.json`).
  SQLite blobs grow the DB file indefinitely; flat files allow
  age-based eviction and visible disk usage per account

### Monitoring
- [ ] Prometheus metrics endpoint
- [ ] Sync lag per account
- [ ] Error rate tracking
- [ ] Storage usage per user

### Spec Compliance
- [ ] IMAP MYRIGHTS for real permissions (currently hardcoded)
- [ ] Email/changes with proper modseq tracking per type
- [ ] Push (EventSource or WebSocket)
- [ ] Quotas (RFC 9425)
- [ ] MDN (RFC 9007)
- [ ] Per-type creation ID mapping (currently shared across types)
- [ ] Gmail: use SMTP envelope for send_email
- [ ] Move raw SQL out of API.pm into DB layer

## Phase 5: Documentation & Developer Experience

- [ ] Landing page with introduction (what is the JMAP proxy, who is it for)
- [ ] Setup guide (Docker, reverse proxy, connecting backends)
- [ ] Clear error messages for missing/invalid config files
- [ ] API documentation for management endpoints
- [ ] SMTP submission error handling and reporting to client

## Non-Goals

- **Be a mail server**: the proxy delegates storage to backends.
  Use Cyrus, Dovecot, or a hosted service for that.
- **Replace Cyrus JMAP**: Cyrus has a native JMAP implementation that's
  faster and more complete.  The proxy is for adding JMAP to servers
  that don't have it, or for aggregating multiple servers.
- **Webmail UI**: the proxy speaks JMAP; pair it with any JMAP client.
