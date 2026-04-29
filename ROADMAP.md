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

### Done (cont.)
- [x] Blob upload/download proxying for JMAP passthrough accounts
- [x] Upload: rewrite accountId in upload URL, proxy binary to upstream
- [x] Download: proxy raw blob responses from upstream (downloadUrl URI template)
- [x] **84/84 JMAP TestSuite tests passing in JMAP passthrough mode** (Cyrus backend)
- [x] Normalise empty notCreated/notUpdated/notDestroyed to null (RFC 8620 §5.3) in passthrough
- [x] JMAPProxy test adapter: cyrus_backend flag propagates Cyrus-specific TODO blocks

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
- [x] IMAP MYRIGHTS for real per-mailbox permissions (RFC 4314, lazy-cached in ifolders)
- [x] MDN/send and MDN/parse (RFC 9007)
- [x] Per-type creation ID mapping (idmap reset per request, createdIds returned in response)
- [x] Move raw SQL out of API.pm into DB layer (EmailSubmission query methods on DB)

### Auth
- [x] Email-first signup UX: email → auto-discovery → OAuth redirect or password form
- [x] PACC discovery (draft-ietf-mailmaint-pacc-02): ua-auto-config.{domain}/.well-known/user-agent-configuration.json
- [x] RFC 8414 OAuth metadata from PACC issuer URL
- [x] Mozilla autoconfig XML fallback (IMAP/SMTP pre-fill, oAuth2 detection)
- [x] PKCE support in OAuth2::Tiny (for public client flows per draft-ietf-mailmaint-oauth-public)
- [x] Gmail OAuth2: GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET env vars → /cb/oauth callback
- [x] Fastmail OAuth2 (OAUTHBEARER IMAP/SMTP via Mail::OAuthBearerTalk, PKCE flow)
- [x] OIDC id_token generation (RS256, auto-generated or loaded RSA key) for webmail SSO
- [x] Encrypted credential storage: pluggable backend (AES-256-GCM default, OpenBao Transit optional)

### Monitoring
- [x] Prometheus metrics endpoint (`GET /metrics` on management port)
- [x] Sync lag per account in metrics
- [ ] Error rate tracking

### Still TODO
- [ ] queryChanges: currently sends spurious removals (spec-compliant but suboptimal)
- [ ] Query result caching for proper queryChanges with filters
- [ ] Move parsed message cache out of SQLite into flat files

## Phase 6: CalDAV/CardDAV Sync ✅

The proxy syncs calendars and contacts from CalDAV/CardDAV backends and exposes
them via the JMAP Calendars (JSCalendar) and Contacts (JSContact) extensions.

### Done
- [x] SRV-based CalDAV/CardDAV discovery (falling back to well-known URLs)
- [x] IMAP hierarchy separator auto-detected from IMAP NAMESPACE (stored in iserver.imapSep)
- [x] Calendar/get, Calendar/changes, Calendar/query, Calendar/set (create/update/destroy)
- [x] CalendarEvent/get, CalendarEvent/changes, CalendarEvent/query, CalendarEvent/set (create/update)
- [x] ContactCard/get, ContactCard/changes, ContactCard/query, ContactCard/set (create/update)
- [x] AddressBook/get, AddressBook/changes, AddressBook/query, AddressBook/set (create/update/destroy)
- [x] JSCalendar ↔ iCalendar conversion via Text::JSCalendar
- [x] JSContact ↔ vCard conversion via Text::JSContact
- [x] Fastmail CalDAV/CardDAV via OAuth Bearer token
- [x] Gmail CalDAV/CardDAV via OAuth Bearer token

### Still TODO
- [ ] CalendarEvent/set destroy
- [ ] Recurrence expansion (CalendarEvent/get with recurrenceOverrides)
- [ ] Free/busy queries

## Phase 7: Code Architecture ✅

Internal refactoring to improve maintainability; no user-visible changes.

### Done
- [x] Sync providers: extract `connect_*` and `send_email` boilerplate into `JMAP::Sync::Common`
      (Standard/Gmail/Fastmail/AOL override only what differs via hook methods)
- [x] API.pm split: decomposed 4,900-line god object into 9 domain files
      (Mailbox, Email, Thread, Calendar, Contact, Submission, Preferences, StorageNode, MDN)
- [x] OAuth extraction: Google/Fastmail/PACC flows into `JMAP::OAuth::*` pure-computation modules;
      PKCE helpers in `JMAP::OAuth::PKCE`; OIDC token generation in `JMAP::OAuth::OIDC`
- [x] Shared `_api_init` helper (begin + get_user + accountId check)
- [x] Shared `_classify_changes` helper (created/updated/destroyed classification)
- [x] Shared `_check_since_state` helper (sinceState + jdeletedmodseq validation)
- [x] Shared `_limit_changes` helper (maxChanges sort/truncate with partial-state update)

## Phase 9: RFC Compliance

Gap analysis (April 2026) against RFC 8620, RFC 8621, draft-ietf-jmap-calendars-26, and RFC 9610.
All referenced specs are in `specs/`.

### RFC 8620 — JMAP Core

#### Blocking
- [x] **Security**: `/upload` and `/raw` (download) endpoints accept any caller who knows an
      `accountId` — no authentication check
- [x] **`downloadUrl` template**: `{type}` variable missing from Session object template;
      `Content-Disposition: attachment; filename="..."` header never set on download responses
- [x] **Request-level errors**: `notJSON`/`notRequest` return plain text, not RFC 7807 JSON
      (`{"type":"urn:ietf:params:jmap:error:notJSON","status":400,...}`)
- [x] **`unknownCapability`**: `using` array not validated — unsupported capabilities silently accepted
- [x] **`invalidResultReference`**: `resolve_args` (API.pm) emits type `'resultReference'`
      instead of `'invalidResultReference'`
- [x] **`accountNotFound`**: already correctly implemented in all API methods (false alarm in review)
- [x] **Quota capability**: implement `Quota/get`, `/query` (live from IMAP `GETQUOTAROOT`);
      `/changes` and `/queryChanges` return `cannotCalculateChanges`
- [x] **SSE ping event**: sends `{servertimestamp:...}` instead of required `{interval:N}`
- [x] **StateChange `@type`**: push object missing required `"@type":"StateChange"` field
- [ ] **`anchor`/`anchorOffset`**: not implemented in any `/query` method; `anchorNotFound`
      error never returned

#### Moderate / Nice-to-have
- [ ] `primaryAccounts` missing `calendars` and `contacts` entries
- [ ] `Cache-Control` header missing from `/session` response
- [ ] `maxCallsInRequest` / `maxSizeRequest` limits not enforced
- [ ] `PushSubscription/get|set` not implemented (SSE works for web clients)
- [ ] `Blob/copy` not implemented
- [ ] Unknown sort → `serverError` instead of `unsupportedSort`
- [ ] Unknown filter → `serverError` instead of `unsupportedFilter`

---

### RFC 8621 — JMAP Mail

#### Blocking
- [ ] **`jmap:mail` accountCapabilities**: returns `{}` — missing 6 required fields:
      `maxMailboxesPerEmail`, `maxMailboxDepth`, `maxSizeMailboxName`,
      `maxSizeAttachmentsPerEmail`, `emailQuerySortOptions`, `mayCreateTopLevelMailbox`
- [ ] **`onDestroyRemoveEmails`**: PARAM_SCHEMA uses `onDestroyRemoveMessages` (wrong name)
- [ ] **`ifInState`**: not enforced in `Mailbox/set`, `Email/set`, or `Email/import`
- [ ] **Email keyword sort comparators**: non-spec `"keyword:$kw"` format used instead of
      `{"property":"hasKeyword","keyword":"$kw"}` Comparator object
- [ ] **`EmailSubmission/changes` `hasMoreChanges`**: duplicate hash key — always `false`
- [ ] **`EmailSubmission/query` sort**: non-spec string format instead of Comparator object
- [ ] **`VacationResponse/get` typo**: returns method name `'VacationReponse/get'` (missing 't')
- [ ] **Identity `replyTo`**: returns a plain string instead of `EmailAddress[]`
- [ ] **`Mailbox/queryChanges`**: not implemented
- [ ] **`Email/parse`**: not implemented
- [ ] **`Identity/changes`** and **`Identity/set`**: not implemented
- [ ] **`VacationResponse/set`**: not implemented

#### Moderate / Nice-to-have
- [ ] `Mailbox/query`: `sortAsTree`, `filterAsTree`, `name`/`role` filter conditions missing
- [ ] `Email/copy` returns `notImplemented` stub
- [ ] `SearchSnippet/get`: subject/preview should be `null` when no text filter match
- [ ] `subParts` included in Email body parts even when not in `bodyProperties`
- [ ] `Thread/get` with `ids:null` will crash (array deref on undef)
- [ ] `EmailSubmission/query` filter missing `identityIds` condition
- [ ] `%ROLE_MAP` duplicate `'junk'` key — second mapping silently wins

---

### draft-ietf-jmap-calendars-26 — JMAP Calendars

#### Blocking
- [ ] **`ParticipantIdentity/get`**: always returns empty list — should return the user's own
      email as a scheduling address
- [ ] **`Calendar/set` `onDestroyRemoveEvents`**: not checked — CalDAV collection deleted
      unconditionally (data loss possible); `calendarHasEvent` SetError never returned
- [ ] **`CalendarEvent` `isOrigin`**: MUST-include property never returned
- [ ] **`CalendarEvent/query` `expandRecurrences`**: not implemented — primary way clients
      find events in a date range
- [ ] **`CalendarEvent/set` error handling**: create errors not caught — client gets false
      success when CalDAV PUT fails; occurrence update/destroy similarly unguarded

#### Moderate
- [ ] Calendar missing `defaultAlertsWithTime`/`defaultAlertsWithoutTime`, `timeZone`,
      `description` properties (not in DB schema)
- [ ] `CalendarEvent/get` missing `isDraft`, `baseEventId`; `utcStart`/`utcEnd` not computed
- [ ] `CalendarEvent/set` does not auto-set `uid`, `created`, `updated`; no `sequence` increment
- [ ] `CalendarEvent/set` `sendSchedulingMessages` silently ignored (no iTIP)
- [ ] `CalendarEvent/query` filter conditions missing (text/title/description/location/
      owner/attendee/uid); date-range uses `start` not `end`; recurring events always pass
- [ ] `CalendarEvent/query` sort not implemented
- [ ] `CalendarEvent/queryChanges` filter not applied
- [ ] `ParticipantIdentity/set` error type wrong (`notImplemented` instead of `forbidden`)
- [ ] Top-level `capabilities` entry for calendars should be `{}` not the account caps object
- [ ] Calendar `myRights` missing `mayShare`; `mayWriteOwn` incorrectly set to `mayWriteAll`

#### Nice-to-have
- [ ] `CalendarEvent/parse`, `CalendarEvent/copy`
- [ ] `Principal/getAvailability` (free/busy)
- [ ] `CalendarEventNotification` (all methods — requires sharing/Principal model)

---

### RFC 9610 — JMAP Contacts

#### Blocking
- [ ] **`AddressBook` `myRights`**: wrong structure — flat properties with wrong names
      (`mayReadItems` etc.) instead of nested `{mayRead, mayWrite, mayShare, mayDelete}`
- [ ] **`AddressBook` `isDefault`**: property missing from schema and all responses
- [ ] **`AddressBook/set` `onSuccessSetIsDefault`**: not implemented
- [ ] **`AddressBook/set` `onDestroyRemoveContacts`**: not checked;
      `addressBookHasContents` SetError never returned
- [ ] **`ContactCard/query`**: calls `_event_filter` (calendar code) instead of
      `_contact_filter` — completely wrong filter; all 13+ spec filter conditions missing
- [ ] **`ContactCard/queryChanges`**: same `_event_filter` bug
- [ ] **`ContactCard/copy`**: method entirely absent — returns `unknownMethod`

#### Moderate
- [ ] `AddressBook` missing `isSubscribed` (has non-spec `isVisible`), `description`,
      `sortOrder`, `shareWith` (should at least be `null`)
- [ ] `AddressBook/set` `ifInState` not checked
- [ ] `AddressBook/set` update only handles `name` — `sortOrder`, `description`,
      `isSubscribed` silently dropped
- [ ] `ContactCard/set` `ifInState` not checked
- [ ] `ContactCard/set` `addressBookIds` on create ignored; moves between books not handled
- [ ] `ContactCard/set` `destroy_contacts` not wrapped in eval — CardDAV error kills worker
- [ ] `ContactCard/query` sort comparators (`created`, `updated`, `name/*`) not implemented
- [ ] `ContactCard/query` `anchor`/`anchorOffset` not implemented
- [ ] Single addressbook per card (structural limit in `jcontacts` schema)

---

## Phase 8: Documentation & Developer Experience

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
