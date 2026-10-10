# FileNode over WebDAV — design

Date: 2026-10-09
Status: approved in conversation; awaiting spec review

## Goal

Implement `urn:ietf:params:jmap:filenode` (draft-ietf-jmap-filenode; the
current source is `~/src/draft-gondwana-jmap-filenode`, docname -15) for
IMAP-backed proxy accounts. The files live on the account's WebDAV server,
the way calendars live on CalDAV and contacts on CardDAV. This replaces
`JMAP/API/StorageNode.pm`, which serves hard-coded fake data.

Success: a JMAP client can browse, create, move, rename, upload, download,
copy, share and delete files on the WebDAV server, and `FileNode/changes`
stays accurate when other clients change the same tree over WebDAV.

## Decisions

- Design for any RFC 4918 server. Use better server features when present:
  RFC 6578 `sync-collection`, a stable server id (`oc:fileid`, RFC 5842
  `DAV:resource-id`), content-derived ETags or `ME:sha1hex`, `getctag`,
  RFC 3744 ACLs.
- Approach A, a metadata mirror: the per-account DB mirrors the tree's
  metadata; every FileNode method reads the mirror; writes go to WebDAV first
  and then update the mirror. File content is never mirrored.
- The code lives in `JMAP/ImapDB.pm` with the other data types (refactor
  later).
- In scope: the core methods (get/changes/set/query/queryChanges with
  `onDestroyRemoveChildren`, `onExists` replace/rename/newest,
  `compareCaseInsensitively`, `fetchParents`, `depth`, `tree` sort), direct
  HTTP PUT write, `FileNode/copy`, and `shareWith` via WebDAV ACLs.
- Out of scope for this version: -15 extended attributes and named streams;
  `onExists: "unchanged"` (needs JMAP-CONDITIONAL, so it is
  `invalidArguments` as the draft requires of servers without it); PATCH
  writes (415); symlinks (WebDAV cannot represent them, so creating one is
  `invalidProperties`); the `body` filter (`unsupportedFilter`).

## Components

The CLAUDE.md process model holds: the parent routes; every WebDAV call and
per-account DB write happens in the account worker; the first full sync runs
in the `"$accountid:backfill"` worker.

- `JMAP/Sync/WebDAVTalk.pm` (new): a `Net::DAVTalk` subclass, protocol only,
  no DB. It adds raw-body requests on DAVTalk's authenticated `ua`:
  - `PropFind($path, $depth, \@props)` returns normalised entries
    `{href, name, isCollection, etag, ctag, size, type, created, modified,
    fileid, fingerprint, privileges, deadprops}`.
  - `SyncCollection($path, $token)` returns `{changed, removed, token}`, or
    "unsupported" on 403/501/invalid token.
  - `Get` (streaming, with `If-Match`), `Put` (with `If-Match` or
    `If-None-Match: *`), `Mkcol`, `Move` and `Copy` (with `Overwrite`),
    `Delete`, `PropPatch`, `GetAcl`, `SetAcl`.
  - Feature probing: the `DAV:` header from OPTIONS, and which properties
    the first PROPFIND returns.
- `JMAP/Sync/Common.pm`: `connect_files()` (as `connect_calendars()`), using
  `iserver.webdavURL`, and the backend commands the worker calls.
- `JMAP/ImapDB.pm`: `sync_files`, reconciliation, the id ladder, and the
  write operations (`create_filenodes`, `update_filenodes`,
  `destroy_filenodes`, `copy_filenodes`, `put_filenode_content`).
- `JMAP/API/FileNode.pm` (new): the `FileNode/*` methods over the mirror.
  `JMAP/API/StorageNode.pm` and its `JMAP::Dispatch` entry are deleted; the
  new methods are added to the method→capability table.
- `bin/jmap-proxy.pl`: the session capability; the
  `PUT /filenode/{accountId}/{id}` route; the `/raw/` download path learns
  the `d-` blob kind; `sync_files_if_due` joins the periodic `sync` command; the
  `/copy` classifier and `_do_copy_call` gain `FileNode/copy`.
- Schema: user DB v12 adds `jfilenodes`, `iserver.webdavURL` and a files
  sync-token column; signup and the accounts flow carry `webdavURL` as they
  do `caldavURL`/`carddavURL`.
- Test backend: `restart-test-proxy.sh clean` builds (once) and runs
  `<CYRUS_IMAGE>-webdav`, a derived image whose `/srv/testserver/imapd.conf`
  has `webdav` in `httpmodules`, and seeds `webdavURL`
  (`<CYRUS_URL>/dav/drive/user/<user>/`).

## Data model

`jfilenodes`, one row per node:

| column | meaning |
|---|---|
| `nodeid` | the JMAP id (see Ids) |
| `parentid` | parent node id; null for the root |
| `name` | the node's name (characters) |
| `href` | the server path |
| `nodetype` | `file` or `directory` |
| `etag`, `ctag` | as last seen; `ctag` for collections |
| `size`, `type` | files only |
| `created`, `modified`, `accessed`, `changed` | UTC seconds |
| `fileid` | the server's stable id, if any |
| `fingerprint` | a content hash, if any |
| `privs` | the current user's privileges, as bits |
| `role`, `executable`, `isSubscribed` | |
| `jcreated`, `jmodseq`, `active` | the usual change tracking; destroys keep the row with `active = 0` |

The account's FileNode state is its highest FileNode `jmodseq`.

## Ids

Ids say where they come from, by prefix:

- `S` + hash of the server's stable id (`oc:fileid` or `DAV:resource-id`).
  It survives any move, whoever makes it.
- `L` + uuid (hex, no dashes), invented by the proxy. It survives moves the proxy makes,
  because MOVE only updates `href` and `parentid`. For moves made
  elsewhere, reconciliation matches a vanished path to a new path with the
  same fingerprint and keeps the id. The fingerprint, strongest first:
  `ME:sha1hex`; a content-derived ETag (Cyrus); size plus
  `getlastmodified`, used only when it is unique in that sync pass.
  Unmatched paths are destroyed or created.

Follow-up, not part of this work: give every data type the same
server/local prefix split. Changing existing ids makes every connected
client resync, so it needs its own plan.

## Root

The `webdavURL` collection is the single top-level node, with role `home`
and `parentId: null`. `mayCreateTopLevelFileNode` is false.

## Blobs

- A file's `blobId` is `d-<nodeid>-<first 16 hex of SHA-1 of its etag>`, the
  same `<letter>-<id>` shape as the existing `f-` and `m-` blobs. When the content
  changes, the ETag changes, so the blobId changes.
- Download (`/raw/`) is a streaming WebDAV GET with `If-Match: <etag>`. A 412
  means that blob no longer exists, and is answered 404.
- Creating or updating a file with a blobId from the proxy's blob store (an
  upload, or another account's content via copy) PUTs those bytes to WebDAV
  and records the resulting ETag.

## Properties without a WebDAV home

`accessed`, `executable`, `isSubscribed`, `role`, client-set
`created`/`modified`, and a `type` set without new content
(`getcontenttype` is a live property; new content, which carries its
type in the PUT, drops it) are stored as dead properties in a proxy namespace
(`https://jmap.io/ns/filenode`) where the server allows PROPPATCH, so other
proxies on the same server see them. Without PROPPATCH they live only in
the mirror. `created`/`modified` are otherwise read from `creationdate` and
`getlastmodified`. Timestamps are whole seconds.

## Sync (`sync_files`)

The proxy's own writes update the mirror directly, so a sync is only needed
to see changes made by other WebDAV clients. A full sync costs one request
per collection (see "Cyrus #drive findings"), so it does not run on every
30-second tick:

- on demand: a FileNode method syncs first when the last sync is more than
  60 seconds old;
- in the background: the periodic `sync` command runs it when the last sync
  is more than 300 seconds old;
- the first full sync runs in the backfill worker.

One sync:

1. Walk every collection, starting at the root, with PROPFIND Depth 1. An
   unchanged collection ETag is NOT a reason to skip its subtree, because
   servers (Cyrus) do not propagate a change to ancestors' ETags.
   `sync-collection` at sync-level 1 (all Cyrus offers) needs the same one
   request per collection, so this version does not use it; a server that
   supports `sync-level: infinite` could sync the whole tree in one REPORT,
   and that is the optimisation to add later (`jfilesync` holds the tokens).
2. Reconciliation classifies every node as created, updated (including a
   matched move), destroyed or unchanged. Each changed row gets the next
   `jmodseq`.

## Defending against bogus servers

The proxy must cope with servers that get WebDAV wrong. Each defence has a
unit test that replays a canned bad response:

- PROPPATCH can answer 200 without storing the property: support for dead
  properties is detected by reading one back, never from the status alone.
- A Depth-0 PROPFIND on a file can return an empty multistatus: a file is
  always refreshed through its parent's Depth-1 listing.
- An ETag can change on MOVE: an ETag is only used as a move fingerprint if
  the server's ETags are shown to be content hashes (a PUT's ETag equals the
  SHA-1 of the bytes) and survive a probe MOVE.
- `sync-level: infinite` can be rejected: sync is per collection.
- Collection ETags can fail to reflect deep changes: never prune on them.
- PROPPATCH of live properties (`getlastmodified`) is usually forbidden:
  client timestamps go to dead properties or the mirror.
- A DELETE of a collection can answer 2xx yet leave it (Cyrus, when it
  has subcollections): subcollections are deleted deepest first, and a
  collection's DELETE is confirmed with a Depth-0 PROPFIND (404).

## Cyrus #drive findings (probe, 2026-10-09)

Enabling `webdav` in `httpmodules` serves `/dav/drive/user/<user>/`.

- MKCOL, PUT (`If-None-Match: *` gives 412 on an existing file), MOVE,
  COPY, DELETE and `If-Match` all work.
- File ETags hash Cyrus's stored resource, not the bytes, and change on MOVE
  and COPY. Collection ETags are `"<uidvalidity>-<n>-<n>"`; the uidvalidity
  survives a MOVE.
- `getlastmodified` survives a MOVE, so size plus `getlastmodified` is the
  usable move fingerprint.
- `sync-collection` works at sync-level 1 per collection (`data:,…`
  tokens); `infinite` is a 400. `Depth: infinity` PROPFIND is a 403.
- A collection's ETag changes only when its direct children change.
- `current-user-privilege-set` reports read, write, write-properties, bind,
  write-content and unbind; `DAV:acl` with `inherited` markers works;
  `quota-used-bytes` is present; `DAV:resource-id` is not.
- Dead-property PROPPATCH on a file answers 200 but nothing is stored.
- A Depth-0 PROPFIND on a file returns an empty multistatus.
- PROPPATCH of `getlastmodified` is 403.
- DELETE of a collection that has subcollections answers 204 but removes
  only its files, keeping itself and every subcollection; from then on a
  DELETE of it answers 500. A collection without subcollections deletes
  cleanly, files and all.
- Restarting the test container breaks its authentication; WebDAV is
  enabled by building a derived image whose `/srv/testserver/imapd.conf`
  template has `webdav` in `httpmodules`.

## Writes (`FileNode/set`)

Each create, update and destroy goes to WebDAV first, ordered so sibling
names stay unique at every step (as the draft requires):

1. destroys whose name a create or move will reuse;
2. creates and moves into the freed names; creates are ordered so `#parent`
   references resolve; swaps and cycles are broken with a temporary name
   (as `hm`'s `_get_ordered_update_keys` does);
3. everything else.

The set is judged by its final state (RFC 8620 S5.3; the draft: "only
check this constraint on the final state"). In practice: destroys, then
creates, then updates (moves, content, properties), then the destroys and
creates that depend on those moves -- a directory whose children an update
moves out is destroyed after the moves (its server-side member check still
runs), and a create whose name a moving node leaves runs after the moves.
A move's cycle check uses the final tree, so a child may move out of its
parent while the parent moves under it; `order_moves` then never sends a
directory into its own current subtree. A parked node whose final MOVE
fails is given back its old name, or the nearest free one, never left
under the temporary name. A late destroy's name is free for creates and
moves in the same call: those run after it. A node that `onExists:
"replace"` displaces is likewise destroyed only once every node leaving it
in this call has left (a node inside it first steps out under a temporary
name in its destination directory), so the replace never deletes a node
that is moving; the displaced node must allow `mayDelete`. A node the
client asked to move or rename counts as moving even when that update is
refused (it stays where it is, and the client did not ask for it to go):
no replace takes its name (`alreadyExists`), and no destroy in the call --
explicit, or on behalf of a replace -- takes it or a directory it is still
inside (`nodeHasChildren`, flag or no flag). `updated` and `notUpdated`
are keyed by the resolved node id, also for a `#cid` key.

Operations:

- Create: a file is PUT with `If-None-Match: *`; a directory is MKCOL; then
  PROPPATCH for dead properties.
- Rename or move: MOVE with `Overwrite: F`. A destination that is the node
  itself or one of its descendants is `invalidProperties` on `parentId`.
- Content change: PUT with `If-Match: <etag in the mirror>`. A 412 means the
  file changed underneath us: the update fails, and the next sync updates
  the mirror.
- `onExists`: `replace` overwrites (`Overwrite: T`) after the
  `nodeHasChildren` check; `rename` tries `name[2].ext`, `name[3].ext`, …;
  `newest` compares `modified` against the mirror; `unchanged` is
  `invalidArguments`.
- Destroy: DELETE. A directory with children is `nodeHasChildren` unless
  `onDestroyRemoveChildren` is set, checked against the mirror, which counts
  children being destroyed in the same call.

After each operation the mirror row is updated from the response (`ETag`,
`Location`) and the parent collection is re-listed.

WebDAV has no transactions, so each create, update and destroy succeeds or
fails on its own and is reported that way. If an item fails partway (the
MOVE succeeded, the PROPPATCH did not), it is `serverFail` and the next sync
reconciles the mirror.

Name validation (`invalidProperties`): non-empty, at most
`maxSizeFileNodeName` UTF-8 octets, none of `forbiddenNameChars`, not in
`forbiddenNodeNames`, no control characters; and the sibling-uniqueness
check honours `compareCaseInsensitively`.

## Copy

Within one account: WebDAV COPY, then PROPFIND for the new nodes, which get
new ids. Across accounts: the parent's existing `/copy` orchestration
fetches the content and creates the nodes in the destination account.
`FileNode/copy` must be listed in the copy classifier (see CLAUDE.md).

## Query

In memory over the mirror:

- every draft filter except `body` (`unsupportedFilter`); `text` is
  `nameMatch` OR `typeMatch`;
- `depth` relative to `parentId` or `ancestorId`;
- sorts `name`, `type`, `size`, `created`, `modified`, `accessed`,
  `nodeType` and `tree`, with `JMAP::Collation`;
- `queryChanges` through the `jqueries` snapshots.

`FileNode/get` supports `fetchParents` and reads the state after the data.

## Sharing

- `myRights` from `DAV:current-user-privilege-set`: `read` → `mayRead`;
  `bind` → `mayAddChildren`; `unbind` on the parent → `mayDelete` (and the
  move half of `mayRename`); `write-content` → `mayModifyContent`;
  `write-acl` → `mayShare`. A server that reports no privilege set gives all
  rights.
- `shareWith` reads and writes the `DAV:acl`, mapping principals to JMAP
  user ids the way calendars do and ignoring inherited ACEs.
- A server without ACL support: `shareWith` is null, and setting it is
  `invalidProperties`.
- After a `shareWith` change, the next sync re-reads privileges below that
  node and bumps the descendants whose derived `myRights` changed, as the
  draft's Access Control section requires.

## Direct HTTP write

`webWriteUrlTemplate` is `{BASEURL}/filenode/{accountId}/{id}`.

- PUT streams through the parent to the worker, then to a WebDAV PUT with
  `If-Match`. It answers `200 {blobId, size, type}`.
- A directory is 400; no `mayModifyContent` is 403; PATCH is 415.

## Capability

The session's top-level `capabilities` gets `"urn:ietf:params:jmap:filenode":
{}` whenever any account has it (the draft requires an empty object there).
The account capability is advertised only for accounts with a `webdavURL`.
`{BASEURL}` below is the proxy's configured base URL, expanded when the
session is built; `{accountId}` and `{id}` stay in the template for the
client to expand.

```json
{
  "maxFileNodeDepth": null,
  "maxSizeFileNodeName": 255,
  "forbiddenNameChars": "/",
  "forbiddenNodeNames": [".", ".."],
  "caseInsensitiveNames": false,
  "mayCreateTopLevelFileNode": false,
  "fileNodeQuerySortOptions": ["name", "type", "size", "created",
    "modified", "accessed", "nodeType", "tree"],
  "webTrashUrl": null,
  "webUrlTemplate": null,
  "webWriteUrlTemplate": "{BASEURL}/filenode/{accountId}/{id}"
}
```

`caseInsensitiveNames` is true only if probing shows the server folds case.
Quota gains `FileNode` in `types` when the server reports
`quota-used-bytes`.

## Testing

- Unit tests for the pure parts: the id ladder and move matching (from
  synthetic before/after listings), reconciliation, set ordering (swaps and
  cycles), glob matching, privilege mapping.
- `t/filenode-webdav.t`: integration against the Cyrus `#drive` test
  backend. It changes the tree with raw WebDAV calls behind the proxy and
  checks `FileNode/changes`, including a move that keeps its id.
- JMAP-TestSuite: there are no FileNode tests yet. Write `t/FileNode/` to
  the draft, asserting only what the draft requires and citing it. Cyrus has
  no FileNode, so there is no `--direct` baseline: every FileNode failure is
  the proxy's.
