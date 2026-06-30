# Passthrough Request Dispatch + Cross-Account Copy — Design

**Date:** 2026-06-30
**Status:** Approved (design phase)
**Branch:** jmap-passthrough (follows the passthrough-finishing work)

## Background

JMAP-to-JMAP passthrough now works for single-account requests: `do_jmap`'s
fast path forwards an entire request to the authenticated account's worker,
which `handle_jmap`-forwards to the upstream in one POST — so `createdIds` and
back-references resolve natively.

Two gaps remain, both exposed by cross-account `Email/copy`:

1. **The copy path drops `createdIds`.** When a request contains a `*/copy`
   call, `_do_jmap_request` pulls the copy calls out for parent orchestration,
   forwards the rest to the auth account's worker, and *reassembles* the
   response as `{ methodResponses, sessionState }` — discarding any
   `createdIds` and breaking creation-id back-references across the split.

2. **Cross-account copy assumes a local IMAP store.** `_copy_emails` and
   `_copy_blobs` use `fetch_blobs` (reads the local synced store → temp file)
   and `store_blob` (hardlinks into the local files dir). Passthrough accounts
   have no local store, so `Email/copy`/`Blob/copy` involving a passthrough
   account fail. (`_copy_objects` for `CalendarEvent`/`ContactCard` uses pure
   JMAP get/set and already works.)

The current dispatcher also forwards *all* non-copy calls to the single
authenticated account, so a request whose method calls target different
accounts is not routed per-account.

## Decisions (from brainstorming)

- **Mechanism:** universal blob-shuffle, with a **native-forward** fast-path
  when both accounts share upstream **credentials**.
- **"Same upstream" = same credentials**, not same hostname (one login may
  expose multiple backend accountIds). Detected via a stored **credential
  fingerprint**.
- **Generalize to batching:** group *consecutive* method calls that share an
  upstream key into a single forwarded request.
- **`createdIds` must be plumbed through** the batches.
- **One spec**, built bottom-up.
- **Test adapter** gains the ability to create the various account
  configurations so the suite exercises each path.

## Design

### A. Upstream key

Each account has an **upstream key** that identifies which upstream (and which
credentials) serves it:

- **Passthrough account:** its `cred_fingerprint` (see §E). Two passthrough
  accounts with the same fingerprint share one upstream login.
- **IMAP account:** a unique per-account key (e.g. `"imap:$accountid"`), so two
  IMAP accounts never share a batch and never qualify for native-forward.

A method call's target account is `args.accountId` (falling back to the
authenticated account when absent). For `*/copy`, the call touches **two**
accounts: `fromAccountId` and `accountId`.

### B. Batching consecutive same-key calls

`_do_jmap_request` is rewritten to:

1. Resolve the upstream key (and type) for every account referenced by the
   request, via a single `__accounts__` lookup (extend `get_pool` /
   `_account_details_child` to return `type`, `cred_fingerprint`, and
   `backendAccountId`).
2. Walk `methodCalls` in order, assigning each call a **route**:
   - a normal call → the key of its target account;
   - a `*/copy` whose `fromAccountId` and `accountId` share a key → that key
     (native-forward, batchable);
   - a `*/copy` across keys → a standalone **`orchestrate`** route.
3. Group maximal **consecutive** runs with the same key into one batch.
   `orchestrate` calls are always standalone (never merged).
4. Forward each batch as one request to a worker for any account on that key
   (for passthrough, any account sharing those creds; for IMAP, that account's
   worker). Native-forward copy calls travel inside their batch.
5. Reassemble `methodResponses` by original position; `orchestrate` calls fill
   their slot from the blob-shuffle result.

A single-account request collapses to exactly one batch — identical behaviour
to today's fast path.

### C. `createdIds` plumbing

Maintain a running `%created_ids` across the ordered batches:

- Seed from the request's `createdIds` (or `{}`).
- Before forwarding batch *n*, set its `createdIds` to the current accumulated
  map (so `#creationId` back-references to earlier batches resolve upstream).
- After batch *n* returns, merge its response `createdIds` into the
  accumulated map.
- `orchestrate` (blob-shuffle copy) calls contribute their created object ids
  to the map as well.
- Return the final accumulated `createdIds` in the response object alongside
  `methodResponses` and `sessionState`.

Within a batch, the upstream resolves both `#creationId` and `ResultReference`
natively. **Limitation (documented):** a `ResultReference` (`resultOf` + path)
pointing into a *different* batch cannot be resolved by a downstream upstream;
only `createdIds` back-references cross batch boundaries. This is acceptable —
cross-account `ResultReference`s are not used in practice.

### D. Copy routing (falls out of A–C)

| from → to | route |
|---|---|
| passthrough → passthrough, **same** fingerprint | native-forward (in-batch) |
| passthrough → passthrough, **different** fingerprint | blob-shuffle |
| passthrough ↔ IMAP (either direction) | blob-shuffle |
| IMAP → IMAP | blob-shuffle (existing) |
| `CalendarEvent`/`ContactCard` copy (any) | `_copy_objects`, unchanged |

**Native-forward is not a separate mechanism** — it is the ordinary batch
forward (§B) applied to a batch that happens to contain a copy call. Because a
batch may span several backend accountIds under one login (e.g. a user and a
shared account it can see), the batch forward carries a **proxy→backend id map**
covering every account on that key, and `handle_jmap` rewrites *all*
account-id fields per that map (today it rewrites only its own single
proxy→backend pair). A `*/copy` call is simply a call with two id fields
(`fromAccountId`, `accountId`/`toAccountId`); the same map rewrites both, and
the responses are rewritten back. This generalises `_rewrite_method_ids` from a
single `(from,to)` pair to a map and is the only worker-side change needed for
native-forward; it preserves threadId/blobId.

### E. Credential fingerprint

New nullable column `cred_fingerprint` in the `accounts` table (schema-version
bump). Computed in the per-account worker at `signup_jmap` and
`update_settings` (where credentials are in hand) as:

```
sha256_hex(join("\0", apiUrl, username, authType, secret))
```

`secret` is the decrypted password/token. Written into `accounts.sqlite3`
alongside the account row (same place `signup_jmap` already writes). `NULL` for
IMAP accounts. The parent never sees raw credentials — only the fingerprint.

### F. Passthrough-aware blob primitives

Used only by the blob-shuffle path (cross-upstream / mixed copy):

- **`fetch_blobs`** (passthrough source): for `m-<emailId>`, forward
  `Email/get [emailId] { properties: ["blobId"] }` upstream, then
  `proxy_blob(blobId)` → temp file; for a raw upstream blobId (`Blob/copy`),
  `proxy_blob` directly. Returns the existing `{ type, path, is_temp }` shape.
- **`store_blob`** (passthrough dest): `proxy_upload(type, path)` → the upstream
  blobId; return `{ blobId => <upstream blobId> }` (not a local `f-` id). The
  subsequent forwarded `Email/import` and the `Blob/copy` response then use that
  upstream blobId.

The IMAP branches of both commands are unchanged. The orchestration in
`_copy_emails`/`_copy_blobs` is unchanged; it transparently covers all four
mixed combinations because it operates at the JMAP/blob level.

### G. Test adapter configurations

Extend `JMAP::TestSuite::ServerAdapter::JMAPProxy` (passthrough mode) to build
the configurations the dispatcher needs to exercise:

- **`pool_account_pair` (different creds):** two distinct Cyrus users, each its
  own passthrough account in one pool → **blob-shuffle** path. (Already created
  by the Task-6 adapter change.)
- **Same-credentials passthrough pair:** create a primary Cyrus user plus a
  second (shared) user, grant the primary access to the shared user (Cyrus
  ACL / delegation) so the primary's JMAP session lists both backend
  accountIds; register two proxy passthrough accounts with identical
  credentials but different `backendAccountId` in one pool → **native-forward**
  path.
- **Mixed pair:** one IMAP account + one passthrough account in one pool →
  **blob-shuffle** mixed path, tested in both directions.

Provide these as adapter methods/attrs the copy tests can select. Where a
configuration can't be expressed for a non-Cyrus backend, the test skips.

### Testing

- **Dispatcher (B/C):** unit-level tests for the batching/grouping function
  (pure: method calls + per-account keys → ordered batches) and `createdIds`
  accumulation. Integration: a request mixing two same-upstream accounts with a
  `#creationId` back-reference resolves correctly; single-account requests are
  unchanged.
- **Copy matrix (D/F):** run `Email/copy` and `Blob/copy` across each adapter
  configuration (native-forward, blob-shuffle different-creds, mixed both
  directions). `Email/copy/basic.t` in `--jmap` mode (different-creds pair) is
  the headline case.
- **Regression:** IMAP-mode `Email/copy`/`Blob/copy` still pass; the full
  `--jmap` suite stays at the Cyrus-native baseline (no proxy-specific
  failures).
- **Baseline comparison:** always diff `--jmap` failures against the `--direct`
  (Cyrus-native) baseline; only proxy-specific deltas are bugs.

## Build order

1. **Credential fingerprint (E)** — schema column + worker computation + expose
   via `__accounts__`. Independent, testable.
2. **Dispatcher with batching + `createdIds` (A/B/C)** — rewrite
   `_do_jmap_request`; generalise `handle_jmap`/`_rewrite_method_ids` to a
   proxy→backend id map so a batch can span several backend accountIds;
   single-account behaviour unchanged. The keystone.
3. **Native-forward copy (D)** — relies on step 2's map rewrite; a same-upstream
   copy call's two id fields are rewritten by the same map. Mostly routing.
4. **Passthrough-aware `fetch_blobs`/`store_blob` (F)** — enables blob-shuffle
   copy for cross-upstream / mixed.
5. **Test adapter configurations (G)** + the copy-matrix tests.

## Out of scope

- Cross-*batch* `ResultReference` resolution (only `createdIds` back-refs cross
  batches).
- `StorageNode`/file (`f-`) blobs for passthrough sources (no passthrough file
  store today).
- Push/SSE for passthrough.

## Risks

- **Reorder/visibility of `createdIds`:** batches must be forwarded strictly in
  order and the accumulated map carried forward, or back-references silently
  break. Covered by the dispatcher unit tests.
- **Fingerprint staleness:** a credential change must recompute the fingerprint
  (handled in `update_settings`); otherwise a stale fingerprint could
  mis-route a copy to native-forward. Native-forward failure should fall back
  to an error the client sees, not silent corruption.
- **Same-credentials test setup** depends on Cyrus delegation/ACLs; if that
  proves fiddly, the native-forward path is still unit-testable via the
  dual-id-rewrite function and a curl/manual check.
