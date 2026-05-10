# JMAP Proxy Roadmap

## Current State (April 2026)

The JMAP proxy syncs email, calendars, and contacts from IMAP/CalDAV/CardDAV
backends and exposes them over the JMAP protocol (RFCs 8620/8621).  It also
supports direct JMAP-to-JMAP passthrough for backends that already speak JMAP.

- **115/115 JMAP TestSuite tests passing** against Cyrus IMAP (87 Email/Mailbox/Thread + 2 Calendar/get + 26 CalendarEvent/AddressBook/ContactCard including set/update, set/destroy, /changes, /queryChanges, and /copy tests)
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
- [x] POST /jmap with auth (standard); legacy /jmap/{accountid} endpoint removed
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
- [x] **102/102 JMAP TestSuite tests passing** (87 Email/Mailbox/Thread + 2 Calendar/get + 13 CalendarEvent/AddressBook/ContactCard)
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
- [x] JMAP TestSuite adapter: session-based URL discovery (GET /session) instead of hardcoded URLs
- [x] JMAP TestSuite: added ifInState tests for Mailbox/set and Email/set; keyword sort comparator test
- [x] JMAP TestSuite: added CalendarEvent, AddressBook, ContactCard entity/comparator/test classes (13 new tests)

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
- [x] Error rate tracking: `jmap_method_errors` counter in Prometheus metrics

### Still TODO
- [x] queryChanges: currently sends spurious removals (spec-compliant but suboptimal) — fixed with jqueries snapshot caching
- [x] Query result caching for proper queryChanges with filters — jqueries table (schema v10), save_query/load_query in DB.pm
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

### Done (cont.)
- [x] CalendarEvent/set destroy: CalDAV DELETE + immediate `delete_event` to mark active=0
- [x] Recurrence expansion: CalendarEvent/get handles `uid/recurrenceId` IDs; `_expand_occurrence`
      merges override patches and strips master-only properties

### Still TODO
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
- [x] **`anchor`/`anchorOffset`**: added `_apply_window` helper in API.pm; all query
      methods now support anchor/anchorOffset/anchorNotFound (Email and Mailbox already
      had it; CalendarEvent, Contact/ContactCard, EmailSubmission, Quota added)

#### Moderate / Nice-to-have
- [x] `primaryAccounts` now includes `calendars` and `contacts` entries when account has CalDAV/CardDAV
- [x] Unknown sort → `unsupportedSort` error (Email/query, Mailbox/query)
- [x] `Cache-Control: no-cache, no-store` added to `/session` response (RFC 8620 §2)
- [x] `maxCallsInRequest` (16) / `maxSizeRequest` (10MB) limits enforced in `do_jmap`
- [x] `PushSubscription/get|set|changes`: `notImplemented` stubs (SSE covers web clients)
- [x] `Blob/copy`: implemented via parent orchestration (filesystem hardlinks)
- [x] Unknown filter → `unsupportedFilter` error; shared `_check_filter` helper in API.pm
      validates condition properties and operator values recursively;
      applied to CalendarEvent/query, CalendarEvent/queryChanges, ContactCard/query

---

### Cross-account `/copy` methods — DONE

RFC 8620/8621, draft-ietf-jmap-calendars, and RFC 9610 all define `/copy`
methods that move objects between accounts:

| Method | Status | Notes |
|--------|--------|-------|
| `Blob/copy` | **implemented** | parent-level orchestration via fetch_blobs/store_blob |
| `Email/copy` | **implemented** | fetch_blobs + store_blob + Email/import |
| `CalendarEvent/copy` | **implemented** | CalendarEvent/get + CalendarEvent/set |
| `ContactCard/copy` | **implemented** | ContactCard/get + ContactCard/set |

All four are implemented via parent-level orchestration in `bin/jmap-proxy.pl`:
the parent intercepts `/copy` method calls before routing to workers, then
drives a multi-step async flow across the source and destination account workers.
Blobs are transferred via filesystem hardlinks (O(1), no data through the socket).
Pool accounts (same `poolid`) are required for cross-account access.
Tests in JMAP-TestSuite cover all four methods with pool_account_pair support.

---

### RFC 8621 — JMAP Mail

#### Blocking
- [x] **`jmap:mail` accountCapabilities**: now returns all 6 required fields
      (`maxMailboxesPerEmail`, `maxMailboxDepth`, `maxSizeMailboxName`,
      `maxSizeAttachmentsPerEmail`, `emailQuerySortOptions`, `mayCreateTopLevelMailbox`)
- [x] **`onDestroyRemoveEmails`**: renamed from `onDestroyRemoveMessages` in PARAM_SCHEMA
      and Mailbox/set handler
- [x] **`ifInState`**: enforced in `Mailbox/set`, `Email/set`, and `Email/import`
- [x] **Email keyword sort comparators**: changed from non-spec `"keyword:$kw"` format to
      `{"property":"hasKeyword","keyword":"$kw"}` Comparator object (`hasKeyword`,
      `allInThreadHaveKeyword`, `someInThreadHaveKeyword`)
- [x] **`EmailSubmission/changes` `hasMoreChanges`**: removed duplicate hash key — was
      always `false` due to Perl last-wins overwrite
- [x] **`EmailSubmission/query` sort**: changed from non-spec string format to Comparator object
- [x] **`VacationResponse/get` typo**: fixed `'VacationReponse/get'` → `'VacationResponse/get'`
- [x] **Identity `replyTo`**: now returns `EmailAddress[]` (or `undef`) instead of plain string
- [x] **`Mailbox/queryChanges`**: implemented; `canCalculateChanges` now `true` in Mailbox/query
- [x] **`Email/parse`**: implemented; fetches blob via `get_blob`, parses with `Data::JSEmail::parse`,
      applies property filtering; JMAP-only fields (`id`, `mailboxIds`, `keywords`, `receivedAt`,
      `threadId`) set to `null`; `notFound`/`notParsable` correctly populated
- [x] **`Identity/changes`**: returns empty changes (state always `'dummy'`; `cannotCalculateChanges` otherwise)
- [x] **`Identity/set`**: creates return `forbiddenFrom`; destroys return `forbidden`; updates persist
      `name`/`textSignature`/`htmlSignature`/`replyTo`/`bcc` in `juserprefs`; `Identity/get` reads them back
- [x] **`VacationResponse/set`**: stores `isEnabled`/`fromDate`/`toDate`/`subject`/`textBody`/`htmlBody`
      in `juserprefs`; `VacationResponse/get` reads back; state is SHA1 of stored payload

#### Moderate / Nice-to-have
- [x] `Mailbox/query`: `sortAsTree` (depth-first pre-order, siblings in sort order) and
      `filterAsTree` (add ancestors of matched mailboxes) implemented
- [x] `Mailbox/query`: `name` (case-insensitive exact) and `role` filter conditions added
- [x] `Thread/get` with `ids:null` now returns all threads (RFC 8620 §5.1)
- [x] `%ROLE_MAP` duplicate `'junk'` key removed (was silently mapping to `'spam'`)
- [x] `Email/copy` — implemented via parent orchestration (see Cross-account /copy section)
- [x] `SearchSnippet/get`: subject/preview now `null` when no text search terms match
- [x] `subParts`: structural recursion preserved for `bodyStructure`; leaf parts return `[]` when explicitly requested
- [x] `EmailSubmission/query` filter `identityIds`: schema v9 adds `identity` column to
      `jsubmission`; saved on create; `_submission_match` predicate fixed (was broken latent bug)

---

### draft-ietf-jmap-calendars-26 — JMAP Calendars

#### Blocking
- [x] **`ParticipantIdentity/get`**: now returns the user's own email as a scheduling address
      (`id1`, `sendTo: {imip: "mailto:user@..."}`) using `account.email`
- [x] **`Calendar/set` `onDestroyRemoveEvents`**: enforced; when false (default) and calendar
      has active events → `calendarHasEvent` SetError; when true → events destroyed first via
      `destroy_calendar_events`, then calendar deleted
- [x] **`CalendarEvent` `isOrigin`**: computed from `organizerCalendarAddress` vs account email;
      `true` if no organizer or organizer matches account; `false` for invited events
- [x] **`CalendarEvent/query` `expandRecurrences`**: implemented — recurring events are
      expanded per `recurrenceRules`/`recurrenceRule` using `DateTime::Event::ICal`;
      occurrences returned as `uid/recurrenceId` IDs, sorted by actual start; moved
      overrides included; non-recurring events filtered by start; `inCalendars` filter
      applied; `canCalculateChanges: false` set in response.
      Also fixed: `create_calendar_events`/`update_calendar_events` now normalize
      RFC 8984 `recurrenceRules` (plural array) → `recurrenceRule` (singular) for
      `Net::CalDAVTalk` / `Text::JSCalendar` compatibility before CalDAV PUT.
- [x] **`CalendarEvent/set` error handling**: create/update/occurrence-update wrapped in
      `eval`; CalDAV failures now return `serverFail` in `notCreated`/`notUpdated` instead
      of crashing the worker

#### Moderate
- [x] Calendar: `description`, `timeZone`, `defaultAlertsWithTime`, `defaultAlertsWithoutTime`
      added to `jcalendars` (schema v8); returned in get; persisted via set create/update
- [x] `CalendarEvent/get`: `isDraft` (false) and `baseEventId` (null) in default response;
      `utcStart`/`utcEnd` computed when explicitly requested (per spec, not in default set)
- [x] `CalendarEvent/set` create: auto-sets `created`/`updated` to current UTC time if absent;
      honors client-provided `uid` (falls back to new UUID); sequence handled by CalDAVTalk
- [x] `CalendarEvent/set` update: auto-sets `updated` to current UTC time if not in patch;
      sequence increment handled by CalDAVTalk `_updateEvent`
- [x] `CalendarEvent/set` update `calendarIds`: now issues CalDAV MOVE to the new collection
      (via `Net::CalDAVTalk::MoveEvent`) and follows up with content PUT if other fields also changed
- [x] `ContactCard/set` create: honors client-provided `uid` (falls back to new UUID)
- [x] `CalendarEvent/set` `sendSchedulingMessages=false`: passes `Schedule-Reply: false`
      HTTP header (RFC 6638 §8.1) and sets `scheduleAgent=client` on all participants
      (RFC 6638 §7.1 `SCHEDULE-AGENT=CLIENT` on ATTENDEE properties); `_no_schedule` flag
      upstreamed to `Net::CalDAVTalk` 0.16 (no longer vendored); occurrence updates forwarded too
- [x] `CalendarEvent/query` filter conditions: `uid`, `text`, `title`, `description`,
      `location`, `owner`, `attendee`; proper date-range overlap (start < before AND end > after);
      recurring masters filtered before expansion; `expandRecurrences` path also applies all filters
- [x] `CalendarEvent/query` sort: `start` (loads payload via cache) and `uid`; `unsupportedSort` for unknown
- [x] `CalendarEvent/queryChanges` filter applied; filter validation added; `jcalendarid`
      fetched so `_event_match` can apply `inCalendar`/payload filters on changed rows
- [x] `ParticipantIdentity/set` error type wrong (`notImplemented` instead of `forbidden`); updates/destroys now also return `forbidden`
- [x] Top-level `capabilities` entry for calendars and contacts now `{}` (per-account caps carry the details)
- [x] Calendar `myRights`: added `mayShare: false`; `mayWriteOwn` now `mayAddItems || mayModifyItems`;
      `isSubscribed` uses `isVisible` (was hardcoded `true`)

#### Nice-to-have
- [x] `CalendarEvent/parse`: implemented via `Text::JSCalendar::vcalendarToEvents`
- [x] `CalendarEvent/copy` — implemented via parent orchestration (see Cross-account /copy section)
- [ ] `Principal/getAvailability` (free/busy)
- [ ] `CalendarEventNotification` (all methods — requires sharing/Principal model)

---

### RFC 9610 — JMAP Contacts

#### Blocking
- [x] **`AddressBook` `myRights`**: restructured to nested `{mayRead, mayWrite, mayShare, mayDelete}`
- [x] **`AddressBook` `isDefault`**: now returned (`false` for all until DB tracks it); `isSubscribed` added
- [x] **`AddressBook/set` `onSuccessSetIsDefault`**: implemented; `isDefault BOOLEAN`
      column added to `jaddressbooks` (schema v6 migration); `AddressBook/get` reads
      it; setting `true` for an ID clears all others and marks that one default;
      `false` just clears that one
- [x] **`AddressBook/set` `onDestroyRemoveContacts`**: enforced; `addressBookHasContents` SetError
      returned when book has contacts and flag is false; contacts destroyed first when flag is true
- [x] **`ContactCard/query`**: fixed `_event_filter` → `_contact_filter`; implemented all
      RFC 9610 §3.3 filter conditions (`inAddressBook`, `uid`, `text`, `name`, `name/given`,
      `name/surname`, `name/surname2`, `nickname`, `organization`, `email`, `phone`, `address`)
- [x] **`ContactCard/queryChanges`**: same `_event_filter` bug fixed
- [x] **`ContactCard/copy`**: implemented via parent orchestration (see Cross-account /copy section)

#### Moderate
- [x] `AddressBook` `description`, `sortOrder` added to `jaddressbooks` (schema v7); returned in get;
      `shareWith` returned as `null` (no sharing model yet)
- [x] `AddressBook/set` `ifInState` not checked
- [x] `AddressBook/set` update: `name` via CardDAV backend; `description`, `sortOrder` persisted
      locally in DB; `isSubscribed` updates `jaddressbooks.isVisible`
- [x] `ContactCard/set` `ifInState` not checked
- [x] `ContactCard/set` `addressBookIds` on create: already resolved via `href_by_jab` lookup (was stale TODO)
- [x] `ContactCard/set` `destroy_contacts` not wrapped in eval — CardDAV error kills worker
- [x] `ContactCard/query` sort: `created`, `updated`, `name`, `name/given`, `name/surname`,
      `name/surname2`; `unsupportedSort` for unknown; stable tie-break by uid
- [x] `ContactCard/query` `anchor`/`anchorOffset` not implemented
- [x] `ContactCard/set` update `addressBookIds`: now issues CardDAV MOVE to the new collection and updates `icards.iaddressbookid` + `jcontacts.jaddressbookid`
- [x] Multiple address books per card / multiple calendars per event: both specs define `maxAddressBooksPerCard` / `maxCalendarsPerEvent` capability fields for exactly this. We now advertise `1` for both and return `invalidProperties` if a client sends >1 truthy entry. True multi-membership would require junction tables + DAV COPY semantics (copies diverge independently — unlike IMAP COPY which shares the blob).

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
