# JMAP Proxy Roadmap

## Current State (April 2026)

The JMAP proxy syncs email, calendars, and contacts from IMAP/CalDAV/CardDAV
backends and exposes them over the JMAP protocol (RFCs 8620/8621).

- **84/84 JMAP TestSuite tests passing** against Cyrus IMAP
- Conversion logic extracted into standalone CPAN modules:
  Data::JSEmail (0.03), Text::JSCalendar (0.03), Text::JSContact (0.01)
- Docker image with single-process architecture and management UI
- Per-account SQLite databases, forked workers per account
- Live deployment at proxy.jmap.io with Bulwark webmail at webmail.jmap.io

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

### Done
- [x] Single-process server (bin/jmap-proxy.pl)
- [x] Non-blocking parent (AnyEvent HTTP), blocking forked children per account
- [x] __accounts__ dedicated child for accounts.sqlite3 CRUD
- [x] Health check endpoint (`GET /healthz` on mgmt port)
- [x] Graceful shutdown (SIGTERM/SIGINT: stop accepting, close children, exit)
- [x] TLS termination documentation (nginx/Caddy examples in ARCHITECTURE.md)
- [x] Idle timeout for backend children (`JMAP_IDLE_TIMEOUT`, default 300s)
- [x] Dockerfile with OCI label, ghcr.io/jmapio/jmap-proxy (public)
- [x] Management REST API (account CRUD, sync triggers, stats)
- [x] Upload via tempfile (avoids binary in JSON socketpair)

### Deployment at proxy.jmap.io
- [x] Docker container with Caddy reverse proxy + auto TLS
- [x] Webmail: Bulwark at webmail.jmap.io, TMail at tmail.jmap.io
- [x] CORS headers for cross-origin webmail clients
- [x] Static demo webmail at /demo/

## Phase 2: Auth & Multi-Account ✅

### Done
- [x] JMAP Session (RFC 8620): GET /.well-known/jmap → /session
- [x] Three auth methods: Basic (email:password), Bearer (token), cookie
- [x] Token system: 256-bit random tokens in `tokens` table, accountid is UUID
- [x] Auth cache: 5 min TTL in parent process
- [x] Account pools: poolid groups linked accounts
- [x] Session response lists all pool accounts with capabilities
- [x] sessionState: SHA1 of sorted pool accountIds
- [x] Signup flow: DNS SRV auto-discovery (IMAP/SMTP/CalDAV/CardDAV)
- [x] Accounts page: add/detach/delete, bearer token display
- [x] POST /jmap with auth (standard) + /jmap/{accountid} (legacy)

### Still TODO
- [ ] Edit account settings (currently set-once at signup)
- [ ] Signup confirmation form integration with /accounts page
- [ ] Token lifecycle: listing, revocation, expiry

## Phase 3: JMAP Backend Passthrough

When a backend already speaks JMAP (Cyrus, Fastmail, etc.), the proxy
should pass requests through directly instead of syncing via IMAP.

### Tasks
- [ ] JMAP client module (HTTP::Tiny + JSON, or LWP)
- [ ] JmapDB.pm backend type (parallel to ImapDB.pm)
- [ ] Request routing by accountId → backend type
- [ ] Blob upload/download proxying
- [ ] Push subscription relay

## Phase 4: Polish & Production Readiness

### Spec Compliance
Done:
- [x] Core/echo (RFC 8620 Section 4)
- [x] sessionState in JMAP responses (RFC 8620)
- [x] Null empty /set result fields (RFC 8620 Section 5.3)
- [x] EmailSubmission state tracking (jstateEmailSubmission)
- [x] Submission capability in Session (maxDelayedSend)
- [x] Quota capability in Session (RFC 9425)
- [x] Tolerate null keyword values in Email/import
- [x] Message-ID uses email domain, not container hostname
- [x] SRV lookup: _submissions._tcp (RFC 8314), skip null records

TODO:
- [ ] IMAP MYRIGHTS for real permissions (currently hardcoded)
- [ ] Push (EventSource or WebSocket)
- [ ] MDN (RFC 9007)
- [ ] Per-type creation ID mapping (currently shared across types)
- [x] onSuccessUpdateEmail/onSuccessDestroyEmail in EmailSubmission/set
- [ ] Move raw SQL out of API.pm into DB layer
- [ ] Schema versioning for SQLite DBs (à la Cyrus dav_db.c): store schema_version
  in a metadata table, apply numbered migrations in sequence, bump version after
  each — replaces scattered `eval { ALTER TABLE }` hacks

### Auth
- [ ] OAuth2 / OpenID Connect support
- [ ] Per-backend credential storage (encrypted at rest)

### Performance
- [ ] Query result caching for proper queryChanges with filters
- [ ] Move parsed message cache out of SQLite into flat files

### Monitoring
- [ ] Prometheus metrics endpoint
- [ ] Sync lag per account
- [ ] Error rate tracking

## Phase 5: Documentation & Developer Experience

- [ ] Landing page with introduction (what is the JMAP proxy, who is it for)
- [ ] Setup guide (Docker, reverse proxy, connecting backends)
- [ ] API documentation for management endpoints
- [x] SMTP submission error handling and reporting to client

## Non-Goals

- **Be a mail server**: the proxy delegates storage to backends.
  Use Cyrus, Dovecot, or a hosted service for that.
- **Replace Cyrus JMAP**: Cyrus has a native JMAP implementation that's
  faster and more complete.  The proxy is for adding JMAP to servers
  that don't have it, or for aggregating multiple servers.
- **Webmail UI**: the proxy speaks JMAP; pair it with any JMAP client.
