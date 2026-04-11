# JMAP Proxy Roadmap

## Current State (April 2026)

The JMAP proxy syncs email, calendars, and contacts from IMAP/CalDAV/CardDAV
backends and exposes them over the JMAP protocol (RFCs 8620/8621).  It also
supports direct JMAP-to-JMAP passthrough for backends that already speak JMAP.

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
│              or JMAP passthrough  │
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
- [x] sessionState: SHA1 of sorted pool accountIds (RFC 8620)
- [x] Signup flow: DNS SRV auto-discovery (IMAP/SMTP/CalDAV/CardDAV)
- [x] Accounts page: add/detach/delete, bearer token display
- [x] POST /jmap with auth (standard) + /jmap/{accountid} (legacy)
- [x] Edit account settings (IMAP/SMTP/DAV credentials and hosts)
- [x] Signup confirmation form: consistent nav and styling
- [x] Token lifecycle: listing, revocation (via Accounts page)
- [x] Schema versioning for SQLite DBs (PRAGMA user_version, versioned migrations)
- [x] Human-readable timestamps on Accounts page ("2 hours ago")
- [x] Stay-in-session when adding a second account (no new token if already logged in)
- [x] Detach button hidden for the active account

## Phase 3: JMAP Backend Passthrough ✅

When a backend already speaks JMAP (Cyrus, Fastmail, etc.), the proxy
passes requests through directly instead of syncing via IMAP.

### Done
- [x] JMAP/JmapDB.pm — new backend type parallel to ImapDB.pm
- [x] Signup: fetch upstream JMAP session, discover apiUrl + backendAccountId
- [x] Request routing: worker branches on account type ('imap' vs 'jmap')
- [x] accountId rewriting: proxy UUID ↔ backend accountId in JSON payloads
- [x] Basic and Bearer auth to upstream
- [x] Edit settings for JMAP accounts (re-verify session URL on save)
- [x] needs_backfill=0 for JMAP accounts (no local sync needed)

### Still TODO
- [ ] Blob upload/download proxying for JMAP passthrough accounts
- [ ] Upload: rewrite accountId in upload URL, proxy binary to upstream
- [ ] Download: proxy raw blob responses from upstream

## Phase 4: Push Notifications ✅

- [x] GET /eventsource — Server-Sent Events endpoint (RFC 8620 §7.3)
- [x] %PushMap routes state changes from workers to open SSE connections
- [x] Per-pool subscriptions: one SSE connection covers all accounts in a pool
- [x] Ping keepalive timer (client-configurable, 30s minimum)
- [x] closeafter=state support
- [x] X-Accel-Buffering: no for Caddy/nginx

## Phase 5: Spec Compliance & Polish

### Done
- [x] Core/echo (RFC 8620 Section 4)
- [x] sessionState in JMAP responses (RFC 8620)
- [x] Null empty /set result fields (RFC 8620 Section 5.3)
- [x] EmailSubmission state tracking (jstateEmailSubmission)
- [x] Submission capability in Session (maxDelayedSend)
- [x] Quota capability in Session (RFC 9425)
- [x] Tolerate null keyword values in Email/import
- [x] Message-ID uses email domain, not container hostname
- [x] SRV lookup: _submissions._tcp (RFC 8314), skip null records
- [x] SMTP submission error handling and reporting to client
- [x] onSuccessUpdateEmail/onSuccessDestroyEmail in EmailSubmission/set
- [x] backfill: separate worker process, needs_backfill flag with schema migration

### Still TODO
- [ ] IMAP MYRIGHTS for real permissions (currently hardcoded isReadOnly=false)
- [ ] MDN (RFC 9007)
- [ ] Per-type creation ID mapping (currently shared across types)
- [ ] Move raw SQL out of API.pm into DB layer
- [ ] queryChanges: currently sends spurious removals (spec-compliant but suboptimal)

### Auth
- [ ] OAuth2 / OpenID Connect support (Gmail, Outlook, etc.)
- [ ] Per-backend credential storage (encrypted at rest)

### Performance
- [ ] Query result caching for proper queryChanges with filters
- [ ] Move parsed message cache out of SQLite into flat files

### Monitoring
- [ ] Prometheus metrics endpoint
- [ ] Sync lag per account
- [ ] Error rate tracking

## Phase 6: Documentation & Developer Experience

- [x] Landing page (proxy.jmap.io/): describes what the proxy is, signup form
- [ ] Setup guide (Docker, reverse proxy, connecting backends)
- [ ] API documentation for management endpoints

## Non-Goals

- **Be a mail server**: the proxy delegates storage to backends.
  Use Cyrus, Dovecot, or a hosted service for that.
- **Replace Cyrus JMAP**: Cyrus has a native JMAP implementation that's
  faster and more complete.  The proxy is for adding JMAP to servers
  that don't have it, or for aggregating multiple servers.
- **Webmail UI**: the proxy speaks JMAP; pair it with any JMAP client.
