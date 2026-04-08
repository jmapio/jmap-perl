# JMAP Proxy Roadmap

## Current State (April 2026)

The JMAP proxy syncs email, calendars, and contacts from IMAP/CalDAV/CardDAV
backends and exposes them over the JMAP protocol (RFCs 8620/8621).

- **81/81 JMAP TestSuite tests passing** against Cyrus IMAP
- Conversion logic extracted into standalone CPAN modules:
  Data::JSEmail, Text::JSCalendar, Text::JSContact
- Per-user SQLite databases, Net::Server::Fork backend
- Single backend per user (IMAP + CalDAV + CardDAV at the same host)

## Phase 1: Docker & Deployment

Package the proxy as a self-contained Docker image.

### Architecture
```
┌──────────────────────────────────┐
│ Docker container                  │
│                                   │
│  :$JMAP_PORT (configurable)       │
│    └─ server.pl (HTTP frontend)   │
│         └─ localhost:5050         │
│              └─ apiendpoint.pl    │
│                                   │
│  :$MGMT_PORT (management UI)     │
│    └─ account CRUD                │
│    └─ backend management          │
│    └─ sync status / triggers      │
│                                   │
│  Volume: /data                    │
│    └─ accounts.sqlite3            │
│    └─ per-account .sqlite3 files  │
└──────────────────────────────────┘
```

### Environment Variables
- `JMAP_PORT` — external JMAP endpoint (default 443)
- `MGMT_PORT` — management UI (default 8080, bind localhost only)
- `JMAP_DATA` — data directory (default /data)

### Tasks
- [ ] Dockerfile with all CPAN dependencies
- [ ] Management web UI (user/account CRUD, backend config, sync status)
- [ ] Health check endpoint
- [ ] Graceful shutdown (drain connections, close DBs)
- [ ] TLS termination (or document reverse proxy setup)

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
- [ ] Connection pooling for IMAP backends (replace fork-per-request)
- [ ] Incremental sync (CONDSTORE/QRESYNC already used, but scheduling)
- [ ] Query result caching for proper queryChanges with filters
- [ ] Lazy body fetching (don't download until client requests)

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
