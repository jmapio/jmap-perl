# JMAP Passthrough — Finishing Design

**Date:** 2026-06-30
**Status:** Approved (design phase)
**Scope:** Make JMAP-to-JMAP passthrough accounts fully functional against the
local Cyrus server, verified by the JMAP-TestSuite running in `--jmap` mode.

## Background

`JMAP::JmapDB` already implements a complete request-forwarding engine for
passthrough accounts:

- `handle_jmap` — forwards a JMAP request to the upstream `apiUrl`, rewriting the
  proxy accountId ↔ the upstream backend accountId in both directions, and
  normalising Cyrus's `{}` → `null` for `notCreated`/`notUpdated`/`notDestroyed`
  (RFC 8620 §5.3).
- `proxy_upload` / `proxy_blob` — blob upload/download with URI-template expansion.
- `fetch_session` + encrypted credential storage (`CredentialStore`), plus Fastmail
  OAuth dynamic registration and refresh-token exchange.

The worker dispatch in `bin/jmap-proxy.pl` branches on `$db->can('handle_jmap')`
for `jmap`/`upload`/`download`/`sync`(no-op)/`backfill`(no-op)/`get_settings`/
`update_settings`/`delete`, and `signup_jmap` creates the account.

Three integration edges remain unfinished and are the subject of this design.

## Problems being fixed

1. **Per-account DB filename mismatch.** `JMAP::JmapDB` stores its per-account
   SQLite file at `$datadir/$accountid.db`, while every other part of the proxy
   reads/deletes `$datadir/$accountid.sqlite3`. This breaks, for passthrough
   accounts:
   - `auth` and `verify_credentials` (read `iserver` from `.sqlite3`) → Basic-auth
     login fails.
   - `_account_details_child` (reads `.sqlite3`) → `/session` reports `configured=0`.
   - account `delete` (unlinks `.sqlite3`) → leaves the `.db` file orphaned.

2. **Auth path is not type-aware.** `auth`/`verify_credentials` read the `iserver`
   table, but passthrough accounts store credentials in the `jserver` table.

3. **`/session` hardcodes IMAP capabilities.** `do_session` always advertises the
   proxy's own IMAP-oriented `capabilities` and `accountCapabilities`, ignoring the
   upstream server's real capabilities (which are available via the upstream
   session).

## Decisions (from brainstorming)

- **Goal:** Cyrus passthrough, verified by the JMAP-TestSuite in `--jmap` mode.
- **Session capabilities:** live-fetched from the upstream on each `/session`.
- **Auth:** compare against stored credentials in the `jserver` table; OAuth-type
  passthrough accounts authenticate via proxy-issued token/cookie only.
- **Test thoroughness:** teach the `JMAPProxy` test adapter to provision passthrough
  accounts in `--jmap` mode, so the full suite (including pristine/pool tests)
  exercises passthrough.

## Design

### 1. Unify the per-account DB file

Change `JMAP::JmapDB` to use `$datadir/$accountid.sqlite3` (matching `JMAP::DB` /
`JMAP::ImapDB`) instead of `$accountid.db`. One account = one file; the existing
`type` column in `accounts.sqlite3` disambiguates which table the file contains
(`jserver` for passthrough, `iserver` for IMAP).

Rationale: the four broken readers (`auth`, `verify_credentials`,
`_account_details_child`, `delete`) all already key off `.sqlite3`. Fixing the
filename at the source removes the mismatch in one place rather than teaching every
reader two filenames.

Migration: passthrough was never deployed, so no production `.db` files exist. No
migration code is needed; `restart-test-proxy.sh clean` wipes local state.

`JMAP::JmapDB::delete` updates to unlink `.sqlite3`.

### 2. Type-aware credential reads (in the `__accounts__` child)

Three handlers in `bin/jmap-proxy.pl` (running in the `__accounts__` child against
`accounts.sqlite3` plus the per-account file) branch on the account `type`:

- **`auth`** — if `type='jmap'`: open the per-account file and
  `SELECT username, password, authType FROM jserver`. For `authType='basic'`,
  decrypt the stored password via `JMAP::CredentialStore` and compare to the
  supplied password; on match, issue a token (same token mechanics as today). For
  `authType` of `bearer` or `fastmail_oauth`, return `undef` (no Basic-auth login —
  the client uses the token issued at signup, or a cookie), mirroring the existing
  gmail/fastmail OAuth behaviour. Otherwise (IMAP): existing `iserver` path,
  unchanged.
- **`verify_credentials`** — same branching as `auth`. OAuth-type jmap accounts
  return `undef` just as gmail/fastmail already do.
- **`_account_details_child`** — for `type='jmap'`, read `jserver` and return
  `configured` (1 if `username` present), `username`, and `type`. It no longer
  needs `caldavURL`/`carddavURL` for jmap accounts because session capabilities are
  live-fetched (§3).

**Observation (out of scope):** the current `auth` handler compares the stored
password to the supplied one *without decrypting*, whereas `verify_credentials`
decrypts. The new jmap path decrypts-and-compares (correct, since
`JMAP::JmapDB::setuser` encrypts). The IMAP-path inconsistency is noted but not
changed by this work.

### 3. Live session-capability assembly (in `do_session`, parent)

`accountCapabilities` is per-account (RFC 8620), so each pool account contributes
its own:

- **IMAP account** → `accountCapabilities` synthesized from `caldavURL`/`carddavURL`
  presence, as today.
- **JMAP passthrough account** → the parent fires a new `session_caps` worker
  command at that account's child (children may block on HTTP; the parent does not).
  The child returns the upstream-derived slice (see §4).

The existing async `get_pool` callback in `do_session` gains a fan-out: for each
jmap account in the pool, fire `session_caps`; collect responses via a counter;
then assemble the session object and respond. For the single-Cyrus-account case
this is one extra backend call.

Assembly rules:

- `accounts.{aid}.accountCapabilities` = the account's contributed capabilities
  (upstream's for jmap, synthesized for imap).
- `accounts.{aid}.name` / `isReadOnly` / `isPersonal` = from the upstream account
  record for jmap accounts; existing defaults for imap.
- Top-level `capabilities` = the proxy's `urn:ietf:params:jmap:core` record plus the
  **union** of every account's contributed capability set.
- `primaryAccounts` = for each capability URN, the first account that is primary for
  it (jmap: from the upstream `primaryAccounts`, backend id rewritten → proxy id;
  imap: mail/submission/calendars/contacts as today).
- URLs (`apiUrl`, `uploadUrl`, `downloadUrl`, `eventSourceUrl`) are always the
  proxy's own (`$BASEURL/...`). Upstream URLs are never exposed to the client.

**Error handling:** if the upstream session fetch fails (network or credential
error), that account degrades to core-only capabilities with a logged warning, and
`/session` still returns 200. A single flaky upstream call must not brick login.

### 4. New `session_caps` worker command (per-account child)

Add a `session_caps` branch to the worker command loop. It requires
`$db->can('handle_jmap')`, calls `fetch_session()` with no override args (uses
stored credentials), parses the upstream session, and returns:

```
['session_caps', {
    accountCapabilities => $upstream->{accounts}{$backendId}{accountCapabilities},
    name                => $upstream->{accounts}{$backendId}{name},
    isReadOnly          => $upstream->{accounts}{$backendId}{isReadOnly},
    isPersonal          => $upstream->{accounts}{$backendId}{isPersonal},
    capabilities        => $upstream->{capabilities},          # top-level, for union
    primaryAccounts     => <upstream primaryAccounts, backendId rewritten to proxy id>,
}]
```

Small, focused, independently testable.

### 5. Test adapter: provision passthrough accounts (`JMAP-TestSuite`)

`bin/restart-test-proxy.sh` (when invoked with `--jmap`) writes a `"backend": "jmap"`
flag into `test-config.json`. The `JMAP::TestSuite::ServerAdapter::JMAPProxy` adapter
reads this flag. In passthrough mode, `_create_pristine_account`:

1. Still creates the Cyrus user via the IMAP admin client (unchanged).
2. Registers the proxy account with the **jmap signup payload** instead of the imap
   payload:
   `{ accountid, sessionUrl => "$cyrus_http_url/jmap", username, password,
      authType => 'basic', poolid? }`.

This makes `pristine_account` and `pool_account_pair` produce passthrough accounts,
so the full suite — including account-provisioning tests — exercises passthrough.

**Dependency to confirm early in implementation:** that `POST /api/accounts` with a
`sessionUrl` (or explicit jmap type) routes to the `signup_jmap` flow in the proxy.

### 6. Verification

1. `bin/restart-test-proxy.sh --jmap clean` to bring up Cyrus and register `user1`
   as a passthrough account.
2. `bin/run-jmap-tests.sh` and capture results.
3. Compare against the `--direct` (Cyrus-native) baseline so that
   Cyrus-inherent failures are distinguished from passthrough-specific ones.
4. Fix passthrough-specific regressions.

**Success bar:** passthrough-mode results match the Cyrus-native (`--direct`)
baseline; any test that passes natively against Cyrus but fails through the proxy is
a passthrough bug to fix.

After verification, update `CLAUDE.md` and project memory with passthrough status.

## Risks

- **accountId rewriting collisions (highest risk).** `handle_jmap` currently rewrites
  accountIds with a blind `s/\Qproxy_id\E/backend_id/g` over the entire JSON string.
  In the test the proxy id is literally `user1`, which will also match
  `user1@example.com` in email addresses/bodies and corrupt them. This is expected to
  cause test failures.
  **Fallback plan:** switch to *structured* rewriting — walk `methodResponses` and
  rewrite only `accountId` fields (and blobId-embedded ids where applicable) instead
  of a string-level regex. The same applies to `proxy_blob`'s blobId rewriting.
- **Upstream session fetch latency.** Live-fetch adds an upstream round-trip per
  `/session`. Acceptable for the goal; mitigated by the degrade-to-core-only error
  path.

## Out of scope

- SSE / push (`eventSource`) passthrough — Phase 4.
- The IMAP-path `auth` decrypt inconsistency noted in §2.
- Caching/refresh of upstream capabilities (live-fetch was chosen).
- Fastmail OAuth passthrough verification against the real backend.

## Testing approach

- Unit coverage for `handle_jmap` accountId rewriting (especially after the
  structured-rewrite change, if triggered) and the type-aware auth branching, added
  under `t/`.
- Integration verification via the JMAP-TestSuite in `--jmap` mode, as in §6.
