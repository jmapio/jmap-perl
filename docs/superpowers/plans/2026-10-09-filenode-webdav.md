# FileNode over WebDAV Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real `urn:ietf:params:jmap:filenode` for IMAP-backed proxy accounts, backed by each account's WebDAV server, replacing the fake `StorageNode` data.

**Architecture:** A per-account metadata mirror (`jfilenodes`) is kept in step with the WebDAV tree by an on-demand/background sync and by the proxy's own writes (WebDAV first, then the mirror). Every `FileNode/*` method reads the mirror. Pure logic (multistatus parsing, ids, reconciliation, name rules, globs, rights, set ordering, filters and sorts) lives in `JMAP/FileNode.pm` so it can be unit-tested against canned bad-server responses; the DB code lives in `JMAP/ImapDB.pm`; the WebDAV protocol lives in `JMAP/Sync/WebDAVTalk.pm`.

**Tech Stack:** Perl 5, SQLite (DBI), `Net::DAVTalk` 0.24 (+ its `Net::DAVTalk::XMLParser`, `XML::Spice`), `HTTP::Tiny`, `HTTP::Date`, `Digest::SHA`, `Data::UUID::LibUUID`, AnyEvent (parent only). Tests: `Test::More` via `prove -l`, and JMAP-TestSuite.

**Spec:** `docs/superpowers/specs/2026-10-09-filenode-webdav-design.md` (read it; the "Defending against bogus servers" and "Cyrus #drive findings" sections drive several tasks). The draft text is `~/src/draft-gondwana-jmap-filenode/draft-ietf-jmap-filenode.mkd`.

## Global Constraints

- The process model in CLAUDE.md is law: no WebDAV call, no per-account DB access and no `get_user()` outside a transaction in the parent; the first full sync runs in the `"$accountid:backfill"` worker.
- Ids: server-derived node ids are `S` + the first 32 hex of SHA-1 of the server's stable id; proxy-invented ids are `L` + a dash-less hex UUID.
- File blobs are `d-<nodeid>-<first 16 hex of SHA-1 of the etag>`.
- Paths are stored as absolute, URI-unescaped server paths without a trailing slash (`/dav/drive/user/user1/docs`); a collection's request path adds `/`.
- Timestamps are whole seconds (epoch in the DB, `YYYY-MM-DDTHH:MM:SSZ` in JMAP).
- Dead properties use namespace `https://jmap.io/ns/filenode` (prefix `J`).
- Capability values (verbatim): `maxFileNodeDepth: null`, `maxSizeFileNodeName: 255`, `forbiddenNameChars: "/"`, `forbiddenNodeNames: [".", ".."]`, `mayCreateTopLevelFileNode: false`, `fileNodeQuerySortOptions: ["name","type","size","created","modified","accessed","nodeType","tree"]`, `webTrashUrl: null`, `webUrlTemplate: null`, `webWriteUrlTemplate: "{BASEURL}/filenode/{accountId}/{id}"` with `{BASEURL}` expanded at session time.
- Sync cadence: on demand when the last file sync is older than 60 s; in the background (the periodic `sync` command) when older than 300 s.
- Every `api_*` sub lives in exactly one module, and every method is in the `JMAP::Dispatch` capability table (`t/dispatch-method-capability.t`).
- Every `/copy` method `_do_copy_call` handles is listed in `JMAP::Dispatch`'s `%COPY_METHODS`.
- Commit straight to `master` (user preference); do not push unless asked.
- Tests run as: `PERL5LIB=$HOME/src/Text-JSCalendar/lib:$HOME/src/Text-JSContact/lib:$PERL5LIB prove -l t/<file>.t` (the two module repos carry fixes newer than the installed copies).

## Review Focus

1. **A server that answers PROPPATCH with 200 but stores nothing** (Cyrus): `executable`/`accessed`/`isSubscribed` must still round-trip, from the mirror. Pinned in Task 2 (probe) and Task 8.
2. **A Depth-0 PROPFIND on a file that returns an empty multistatus** (Cyrus): refreshing one file after a PUT must not lose the node. Pinned in Task 2 and Task 7.
3. **A file moved by another WebDAV client whose ETag changes on MOVE** (Cyrus): the node keeps its id when size + `getlastmodified` match uniquely, and becomes destroy + create when they don't. Pinned in Task 4.
4. **Names that need URI escaping** (spaces, `%`, `#`, `?`, non-ASCII, `name[2].ext`): every WebDAV call must escape exactly once, and hrefs from the server must be unescaped once. Pinned in Task 2 and Task 7.
5. **A FileNode/set whose operations collide with each other** (swap two names; destroy `a` and create `a`; move a dir into its own child; create a child of a node created in the same call): end state is unique names, `invalidProperties` for the cycle, and `#ref` parents resolved. Pinned in Task 6 and Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `JMAP/Sync/WebDAVTalk.pm` (new) | WebDAV protocol: requests, multistatus normalisation, feature probing. No DB. |
| `JMAP/FileNode.pm` (new) | Pure logic: ids, blob ids, name rules, globs, rights, reconciliation, set ordering, filters, sorts. No I/O. |
| `JMAP/Sync/Common.pm` | `connect_files()`, `_webdav_url()`, and the `files_*` backend commands the worker calls via `backend_cmd`. |
| `JMAP/DB.pm` | Schema v12 (migration), `%TABLE2GROUPS` entry, `get_blob` learns `d-`. |
| `JMAP/ImapDB.pm` | `iserver.webdavURL` column; `sync_files`, `sync_files_if_due`; mirror writes; `create/update/destroy/copy_filenodes`; `put_filenode_content`; dead-property storage; ACL read/write. |
| `JMAP/API/FileNode.pm` (new) | `FileNode/get/changes/set/copy/query/queryChanges`. |
| `JMAP/API/StorageNode.pm` | Deleted. |
| `JMAP/API.pm` | `require JMAP::API::FileNode` instead of `StorageNode`. |
| `JMAP/Dispatch.pm` | Method table: drop `StorageNode/*`, add `FileNode/*`; `%COPY_METHODS` gains `FileNode/copy`. |
| `JMAP/Capabilities.pm` | `urn:ietf:params:jmap:filenode` account capability when `webdavURL` is set; Quota types. |
| `bin/jmap-proxy.pl` | Session top-level capability; `webWriteUrlTemplate` expansion; `PUT /filenode/...` route; signup/account-details carry `webdavURL`; `sync` runs `sync_files_if_due(300)`; `_do_copy_call` handles `FileNode/copy`. |
| `bin/restart-test-proxy.sh` | Build/run `<CYRUS_IMAGE>-webdav`; seed `webdavURL`. |
| `t/filenode-pure.t`, `t/filenode-reconcile.t`, `t/filenode-order.t`, `t/filenode-query.t`, `t/webdavtalk-parse.t` (new) | Unit tests. |
| `t/webdavtalk-live.t`, `t/filenode-webdav.t` (new) | Integration against Cyrus `#drive` (skip unless `CYRUS_URL`). |
| `~/src/JMAP-TestSuite/t/FileNode/*.t` (new, other repo) | Spec tests for the draft. |
| `CLAUDE.md`, `ROADMAP.md` | Documentation. |

---

### Task 1: Test backend, schema v12 and `webdavURL` plumbing

**Files:**
- Modify: `bin/restart-test-proxy.sh` (the `clean` container block and the account-creation JSON near line 110-125)
- Modify: `JMAP/DB.pm` (`$USER_SCHEMA_VERSION`, `%TABLE2GROUPS`, `account` table, `_initdb` migrations)
- Modify: `JMAP/ImapDB.pm` (`iserver` CREATE TABLE near line 3480, `_create_user_tables`)
- Modify: `bin/jmap-proxy.pl` (`_account_details_child` ~line 1275; the signup handlers that pass `caldavURL` at ~lines 546, 658, 3323, 3558; the signup HTML form at ~line 4334)
- Test: `t/filenode-schema.t` (new)

**Interfaces:**
- Produces: tables `jfilenodes`, `jfilesync`; columns `iserver.webdavURL`, `iserver.webdavFeatures` (JSON text), `iserver.lastfilesync` (epoch), `account.jstateFileNode`; `%TABLE2GROUPS{jfilenodes} = ['FileNode']`; `_account_details_child` returns `webdavURL`.

- [ ] **Step 1: Write the failing schema test**

```perl
#!/usr/bin/perl
# t/filenode-schema.t
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
$JMAP::DB::DATADIR = $ENV{JMAP_DATADIR};

my $db = JMAP::ImapDB->new('schematest');
my $dbh = $db->dbh;

my ($v) = $dbh->selectrow_array('PRAGMA user_version');
is($v, 12, 'user schema is v12');

my %cols = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(jfilenodes)') };
ok($cols{$_}, "jfilenodes.$_") for qw(nodeid parentid name href nodetype etag ctag size
  type created modified accessed changed fileid fingerprint privs role executable
  isSubscribed deadprops jcreated jmodseq mtime active);

my %is = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(iserver)') };
ok($is{$_}, "iserver.$_") for qw(webdavURL webdavFeatures lastfilesync);

my %acct = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(account)') };
ok($acct{jstateFileNode}, 'account.jstateFileNode');

my %sync = map { $_->[1] => 1 } @{ $dbh->selectall_arrayref('PRAGMA table_info(jfilesync)') };
ok($sync{$_}, "jfilesync.$_") for qw(href token mtime);

done_testing;
```

- [ ] **Step 2: Run it to see it fail**

Run: `prove -l t/filenode-schema.t`
Expected: FAIL — `user schema is v12` gets 11, and the columns are missing.

(If `JMAP::ImapDB->new` needs more setup than shown, copy the minimal construction used by `t/submission-hold.t`/existing DB tests; the point is a fresh per-account DB created at the current schema.)

- [ ] **Step 3: Add the tables and the migration**

In `JMAP/DB.pm`:

```perl
my $USER_SCHEMA_VERSION = 12;
```

Add to `%TABLE2GROUPS`:

```perl
  jfilenodes => ['FileNode'],
```

In the `account` CREATE TABLE, after `jstateEmailSubmission`:

```perl
  jstateFileNode TEXT NOT NULL DEFAULT 1,
```

In `_create_user_tables` (base class), add:

```perl
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfilenodes (
  nodeid TEXT PRIMARY KEY,
  parentid TEXT,
  name TEXT,
  href TEXT,
  nodetype TEXT,
  etag TEXT,
  ctag TEXT,
  size INTEGER,
  type TEXT,
  created INTEGER,
  modified INTEGER,
  accessed INTEGER,
  changed INTEGER,
  fileid TEXT,
  fingerprint TEXT,
  privs TEXT,
  role TEXT,
  executable INTEGER,
  isSubscribed INTEGER,
  deadprops TEXT,
  jcreated INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF
  $dbh->do("CREATE INDEX IF NOT EXISTS jfilenodeparent ON jfilenodes (parentid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS jfilenodehref ON jfilenodes (href)");
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfilesync (
  href TEXT PRIMARY KEY,
  token TEXT,
  mtime DATE
);
EOF
```

In `_initdb`, after the `if ($v < 11)` block:

```perl
  if ($v < 12) {
    # FileNode over WebDAV: the metadata mirror, per-collection sync tokens,
    # the FileNode state, and the account's WebDAV settings.
    $dbh->begin_work;
    eval {
      $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfilenodes (
  nodeid TEXT PRIMARY KEY, parentid TEXT, name TEXT, href TEXT, nodetype TEXT,
  etag TEXT, ctag TEXT, size INTEGER, type TEXT, created INTEGER,
  modified INTEGER, accessed INTEGER, changed INTEGER, fileid TEXT,
  fingerprint TEXT, privs TEXT, role TEXT, executable INTEGER,
  isSubscribed INTEGER, deadprops TEXT, jcreated INTEGER, jmodseq INTEGER,
  mtime DATE, active BOOLEAN
)
EOF
      $dbh->do("CREATE INDEX IF NOT EXISTS jfilenodeparent ON jfilenodes (parentid)");
      $dbh->do("CREATE INDEX IF NOT EXISTS jfilenodehref ON jfilenodes (href)");
      $dbh->do("CREATE TABLE IF NOT EXISTS jfilesync (href TEXT PRIMARY KEY, token TEXT, mtime DATE)");
      $dbh->do("ALTER TABLE account ADD COLUMN jstateFileNode TEXT NOT NULL DEFAULT 1");
      # iserver only exists for IMAP-backed accounts
      for my $col ('webdavURL TEXT', 'webdavFeatures TEXT', 'lastfilesync INTEGER') {
        eval { $dbh->do("ALTER TABLE iserver ADD COLUMN $col") };
      }
      $dbh->do('PRAGMA user_version = 12');
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "user DB migration to v12 failed: $@" }
    $v = 12;
  }
```

In `JMAP/ImapDB.pm`'s `iserver` CREATE TABLE, after `carddavURL TEXT,`:

```perl
  webdavURL TEXT,
  webdavFeatures TEXT,
  lastfilesync INTEGER,
```

- [ ] **Step 4: Run the schema test**

Run: `prove -l t/filenode-schema.t`
Expected: PASS.

- [ ] **Step 5: Carry `webdavURL` like `caldavURL`**

In `bin/jmap-proxy.pl`:

- `_account_details_child` (~line 1305): add `webdavURL => $iserver->{webdavURL},` next to `carddavURL`.
- Every `setuser({...})` call that passes `carddavURL` (~lines 546, 658): add `webdavURL => $args->{webdavURL} || '',`.
- The key list at ~line 3323: add `webdavURL` after `carddavURL`.
- The form parse at ~line 3558: add `webdavURL => $req->parm('webdavURL') || '',`.
- The signup page JS at ~line 4334: add `webdavURL: (document.getElementById('f-webdav') || {}).value || '',` and add an `f-webdav` text input labelled "WebDAV URL (files, optional)" beside the CardDAV one.

- [ ] **Step 6: Make the test stack run Cyrus with WebDAV**

In `bin/restart-test-proxy.sh`, where `clean` recreates the container from `"${CYRUS_IMAGE:-ghcr.io/cyrusimap/cyrus-docker-test-server:latest}"`, replace that image reference with a derived image built on demand:

```bash
BASE_IMAGE="${CYRUS_IMAGE:-ghcr.io/cyrusimap/cyrus-docker-test-server:latest}"
WEBDAV_IMAGE="${BASE_IMAGE%%:*}-webdav:${BASE_IMAGE##*:}"
[ "$WEBDAV_IMAGE" = "$BASE_IMAGE-webdav:$BASE_IMAGE" ] && WEBDAV_IMAGE="${BASE_IMAGE}-webdav"
if ! docker image inspect "$WEBDAV_IMAGE" >/dev/null 2>&1; then
  # Cyrus regenerates /etc/imapd.conf from this template at every boot, and
  # restarting the container breaks its auth, so WebDAV has to be baked in.
  printf 'FROM %s\nRUN sed -i "s/^httpmodules: .*/httpmodules: caldav carddav jmap webdav/" /srv/testserver/imapd.conf\n' \
    "$BASE_IMAGE" | docker build -q -t "$WEBDAV_IMAGE" - >/dev/null
fi
```

and use `"$WEBDAV_IMAGE"` in the `docker run`. In the IMAP account-creation JSON add:

```bash
                \"webdavURL\": \"$CYRUS_URL/dav/drive/user/$CYRUS_USER/\",
```

- [ ] **Step 7: Verify the stack**

Run: `bin/restart-test-proxy.sh clean > /tmp/rt.log 2>&1; curl -s -o /dev/null -w '%{http_code}\n' -u user1:password -X PROPFIND -H 'Depth: 0' http://localhost:8080/dav/drive/user/user1/; sqlite3 /tmp/jmap-proxy-test/user1.sqlite3 'select webdavURL from iserver'`
Expected: `207`, and `http://localhost:8080/dav/drive/user/user1/`.
(Never pipe the restart script — it backgrounds the proxy; redirect to a file.)

- [ ] **Step 8: Run the existing unit tests, then commit**

Run: `prove -l t/` — expected PASS.

```bash
git add JMAP/DB.pm JMAP/ImapDB.pm bin/jmap-proxy.pl bin/restart-test-proxy.sh t/filenode-schema.t
git commit -m "files: schema v12 and webdavURL plumbing for FileNode over WebDAV"
```

---

### Task 2: `JMAP::Sync::WebDAVTalk` — protocol client and multistatus normalisation

**Files:**
- Create: `JMAP/Sync/WebDAVTalk.pm`
- Test: `t/webdavtalk-parse.t` (unit, canned XML), `t/webdavtalk-live.t` (integration, skips without `CYRUS_URL`)

**Interfaces:**
- Produces:
  - `JMAP::Sync::WebDAVTalk->new(user => $u, password => $p, url => $rootUrl)` (a `Net::DAVTalk`).
  - `JMAP::Sync::WebDAVTalk::parse_multistatus($xml) -> [ $entry, ... ]` (class function) where `$entry` is a hashref:
    `{ href => '/abs/unescaped/path', missing => 0|1, isCollection => 0|1, etag => 'unquoted'|undef, ctag => ..., size => int|undef, type => 'text/plain'|undef, created => epoch|undef, modified => epoch|undef, fileid => string|undef, sha1 => hex|undef, privileges => ['read', ...]|undef, dead => { name => value, ... } }`.
    `missing` is 1 for a response whose status is 404 (sync-collection removal). `href` never has a trailing slash (root: the basepath).
  - `$dav->PropFind($path, $depth) -> [entries]` (dies on non-207 with the status in the message).
  - `$dav->SyncCollection($path, $token) -> { entries => [...], token => $newToken }` or `undef` when the server refuses (non-207, or 403/409/400 for a token).
  - `$dav->Raw($method, $path, $body, %headers) -> { status, headers, content }` (`$path` absolute unescaped; a collection path should end in `/`).
  - `$dav->Get($path, if_match => $etag) -> { status, content, type, etag }`
  - `$dav->Put($path, $bytes, type => $mime, if_match => $etag | if_none_match => 1) -> { status, etag }`
  - `$dav->Mkcol($path) -> $status`; `$dav->Move($from, $to, overwrite => 0|1) -> $status`; `$dav->Copy($from, $to, overwrite => 0|1) -> $status`; `$dav->Delete($path) -> $status`
  - `$dav->PropPatch($path, { name => value|undef, ... }) -> $status` (dead props in the `J` namespace; `undef` removes)
  - `$dav->GetAcl($path) -> [ { principal => '/principal/href/' | 'self' | 'all' | 'authenticated', grant => ['read', ...], inherited => 0|1 } ]`
  - `$dav->SetAcl($path, [ { principal => ..., grant => [...] } ]) -> $status`
  - `$dav->Probe($rootPath) -> { syncCollection => 0|1, acl => 0|1, deadProps => 0|1, etagIsContent => 0|1, quota => 0|1 }` (creates and removes a scratch file `.jmap-probe-<uuid>` in the root).

- [ ] **Step 1: Write the failing parse test with canned responses (including Cyrus's bad ones)**

```perl
#!/usr/bin/perl
# t/webdavtalk-parse.t
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::WebDAVTalk;

my $parse = \&JMAP::Sync::WebDAVTalk::parse_multistatus;

# A Cyrus #drive Depth-1 listing (trimmed from the 2026-10-09 probe).
my $listing = <<'XML';
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
  <D:response>
    <D:href>/dav/drive/user/user1/docs/</D:href>
    <D:propstat><D:prop>
      <D:getetag>"1791596669-1-1"</D:getetag>
      <D:getlastmodified>Sat, 10 Oct 2026 01:44:12 GMT</D:getlastmodified>
      <D:creationdate>2026-10-10T01:44:12Z</D:creationdate>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    <D:propstat><D:prop><CS:getctag/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/drive/user/user1/docs/a%20b%25%23.txt</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>5</D:getcontentlength>
      <D:getcontenttype>text/plain</D:getcontenttype>
      <D:getetag>"e91bbad412cd27c0ffcb9c6031ce0e4c433f59b5"</D:getetag>
      <D:getlastmodified>Sat, 10 Oct 2026 01:45:31 GMT</D:getlastmodified>
      <D:resourcetype/>
      <D:current-user-privilege-set>
        <D:privilege><D:read/></D:privilege>
        <D:privilege><D:write-content/></D:privilege>
        <D:privilege><D:bind/></D:privilege>
      </D:current-user-privilege-set>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/drive/user/user1/docs/caf%C3%A9.txt</D:href>
    <D:status>HTTP/1.1 404 Not Found</D:status>
  </D:response>
</D:multistatus>
XML

my $e = $parse->($listing);
is(scalar @$e, 3, 'three responses');
is($e->[0]{href}, '/dav/drive/user/user1/docs', 'collection href without trailing slash');
ok($e->[0]{isCollection}, 'collection detected');
is($e->[0]{etag}, '1791596669-1-1', 'etag unquoted');
is($e->[0]{ctag}, undef, '404 propstat ignored');
is($e->[0]{created}, 1791596652, 'creationdate parsed');
is($e->[1]{href}, '/dav/drive/user/user1/docs/a b%#.txt', 'href unescaped exactly once');
ok(!$e->[1]{isCollection}, 'file');
is($e->[1]{size}, 5, 'size');
is($e->[1]{type}, 'text/plain', 'type');
is($e->[1]{modified}, 1791596731, 'getlastmodified parsed');
is_deeply([ sort @{ $e->[1]{privileges} } ], [qw(bind read write-content)], 'privileges');
ok($e->[2]{missing}, 'top-level 404 status is a removal');
is($e->[2]{href}, "/dav/drive/user/user1/docs/caf\x{e9}.txt", 'UTF-8 percent-escapes decode to characters');

# Cyrus answers a Depth-0 PROPFIND on a file with an empty multistatus.
my $empty = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:" xmlns:J="https://jmap.io/ns/filenode">\n\n};
is_deeply($parse->($empty), [], 'an empty (even unterminated) multistatus is no entries, not a crash');

# Dead properties, oc:fileid and ME:sha1hex.
my $dead = <<'XML';
<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:" xmlns:J="https://jmap.io/ns/filenode" xmlns:oc="http://owncloud.org/ns" xmlns:ME="https://www.fastmail.com/dav/">
  <D:response><D:href>/f/x</D:href><D:propstat><D:prop>
    <J:executable>1</J:executable><J:accessed>2026-10-01T00:00:00Z</J:accessed>
    <oc:fileid>00001234ocabc</oc:fileid><ME:sha1hex>aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d</ME:sha1hex>
  </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>
XML
my ($d) = @{ $parse->($dead) };
is_deeply($d->{dead}, { executable => '1', accessed => '2026-10-01T00:00:00Z' }, 'dead properties');
is($d->{fileid}, '00001234ocabc', 'oc:fileid');
is($d->{sha1}, 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d', 'ME:sha1hex');

done_testing;
```

- [ ] **Step 2: Run it to see it fail**

Run: `prove -l t/webdavtalk-parse.t`
Expected: FAIL — `Can't locate JMAP/Sync/WebDAVTalk.pm`.

- [ ] **Step 3: Implement the module**

```perl
package JMAP::Sync::WebDAVTalk;

# WebDAV (RFC 4918) for FileNode: requests and multistatus normalisation.
# Protocol only -- no DB.  Paths are absolute and URI-unescaped; request_url
# (Net::DAVTalk) escapes each segment exactly once.

use strict;
use warnings;
use parent 'Net::DAVTalk';
use Net::DAVTalk::XMLParser;
use Encode qw(decode_utf8 encode_utf8);
use URI::Escape qw(uri_unescape);
use HTTP::Date qw(str2time);
use Digest::SHA qw(sha1_hex);
use Data::UUID::LibUUID qw(new_uuid_string);

our $NS_J = 'https://jmap.io/ns/filenode';
my $D = '{DAV:}';

sub _list { my $v = shift; return () unless defined $v; return ref $v eq 'ARRAY' ? @$v : ($v) }
sub _text { my $v = shift; return ref $v eq 'HASH' ? $v->{content} : $v }

sub _unescape_href {
  my $href = shift // '';
  $href =~ s{^https?://[^/]+}{};
  my $path = uri_unescape($href);
  $path = eval { decode_utf8($path, Encode::FB_CROAK) } // $path;
  $path =~ s{/+$}{} if length $path > 1;
  return $path;
}

# RFC 4918 S14.16: a multistatus of responses.  Returns normalised entries.
sub parse_multistatus {
  my ($xml) = @_;
  return [] unless defined $xml && $xml =~ /<[^?!]/;
  my $tree = eval { xmlToHash($xml) };
  return [] unless $tree;
  my @entries;
  for my $resp (_list($tree->{"${D}response"})) {
    my %e = (href => _unescape_href(_text($resp->{"${D}href"})), dead => {});
    my $topstatus = _text($resp->{"${D}status"});
    if ($topstatus && $topstatus =~ / 404 /) {
      $e{missing} = 1;
      push @entries, \%e;
      next;
    }
    for my $ps (_list($resp->{"${D}propstat"})) {
      my $status = _text($ps->{"${D}status"}) // '';
      next unless $status =~ / 2\d\d /;
      my $prop = $ps->{"${D}prop"} || {};
      for my $key (keys %$prop) {
        my $val = $prop->{$key};
        if    ($key eq "${D}getetag")            { ($e{etag} = _text($val) // '') =~ s/^(?:W\/)?"|"$//g }
        elsif ($key eq '{http://calendarserver.org/ns/}getctag') { $e{ctag} = _text($val) }
        elsif ($key eq "${D}getcontentlength")   { my $t = _text($val); $e{size} = (defined $t && length $t) ? $t + 0 : undef }
        elsif ($key eq "${D}getcontenttype")     { my $t = _text($val); $e{type} = (defined $t && length $t) ? $t : undef }
        elsif ($key eq "${D}getlastmodified")    { $e{modified} = str2time(_text($val) // '') }
        elsif ($key eq "${D}creationdate")       { $e{created} = str2time(_text($val) // '') }
        elsif ($key eq "${D}resourcetype")       { $e{isCollection} = (ref $val eq 'HASH' && exists $val->{"${D}collection"}) ? 1 : 0 }
        elsif ($key eq '{http://owncloud.org/ns}fileid' || $key eq "${D}resource-id") {
          my $t = $key eq "${D}resource-id" ? _text($val->{"${D}href"}) : _text($val);
          $e{fileid} = $t if defined $t && length $t;
        }
        elsif ($key eq '{https://www.fastmail.com/dav/}sha1hex') { $e{sha1} = lc(_text($val) // '') || undef }
        elsif ($key eq "${D}current-user-privilege-set") {
          $e{privileges} = [ map { my $p = $_; map { s/^\{DAV:\}//r } grep { /^\{DAV:\}/ } keys %$p }
                             map { _list($_) } $val->{"${D}privilege"} ];
        }
        elsif ($key =~ /^\{\Q$NS_J\E\}(.+)$/) { $e{dead}{$1} = _text($val) }
      }
    }
    $e{isCollection} //= 0;
    push @entries, \%e;
  }
  return \@entries;
}

my $PROPFIND_BODY = <<"XML";
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/" xmlns:J="$NS_J" xmlns:oc="http://owncloud.org/ns" xmlns:ME="https://www.fastmail.com/dav/">
  <D:prop>
    <D:resourcetype/><D:getetag/><D:getcontentlength/><D:getcontenttype/>
    <D:getlastmodified/><D:creationdate/><D:resource-id/><CS:getctag/>
    <D:current-user-privilege-set/><oc:fileid/><ME:sha1hex/>
    <J:executable/><J:accessed/><J:created/><J:modified/><J:isSubscribed/><J:role/>
  </D:prop>
</D:propfind>
XML

sub Raw {
  my ($Self, $method, $path, $body, %headers) = @_;
  $headers{Authorization} = $Self->auth_header() if $Self->{user};
  my $res = $Self->ua->request($method, $Self->request_url($path), {
    headers => \%headers,
    (defined $body ? (content => $body) : ()),
  });
  return { status => $res->{status}, headers => $res->{headers} || {}, content => $res->{content} };
}

sub _xml { my ($Self, $method, $path, $xml, %h) = @_;
  return $Self->Raw($method, $path, encode_utf8($xml), 'Content-Type' => 'application/xml; charset=utf-8', %h) }

sub PropFind {
  my ($Self, $path, $depth) = @_;
  my $res = $Self->_xml('PROPFIND', $path, $PROPFIND_BODY, Depth => $depth // 1);
  die "PROPFIND $path: HTTP $res->{status}\n" unless $res->{status} == 207;
  return parse_multistatus($res->{content});
}

sub SyncCollection {
  my ($Self, $path, $token) = @_;
  my $body = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:sync-collection xmlns:D="DAV:">}
           . '<D:sync-token>' . ($token // '') . '</D:sync-token><D:sync-level>1</D:sync-level>'
           . ($PROPFIND_BODY =~ /(<D:prop>.*<\/D:prop>)/s)[0] . '</D:sync-collection>';
  $body =~ s/<D:sync-collection xmlns:D="DAV:">/<D:sync-collection xmlns:D="DAV:" xmlns:CS="http:\/\/calendarserver.org\/ns\/" xmlns:J="$NS_J" xmlns:oc="http:\/\/owncloud.org\/ns" xmlns:ME="https:\/\/www.fastmail.com\/dav\/">/;
  my $res = $Self->_xml('REPORT', $path, $body, Depth => 1);
  return undef unless $res->{status} == 207;
  my ($tok) = ($res->{content} // '') =~ m{<(?:\w+:)?sync-token>([^<]*)</(?:\w+:)?sync-token>};
  return undef unless defined $tok;
  return { entries => parse_multistatus($res->{content}), token => $tok };
}

sub Get {
  my ($Self, $path, %o) = @_;
  my $res = $Self->Raw('GET', $path, undef, ($o{if_match} ? ('If-Match' => qq{"$o{if_match}"}) : ()));
  (my $etag = $res->{headers}{etag} // '') =~ s/^(?:W\/)?"|"$//g;
  return { status => $res->{status}, content => $res->{content},
           type => $res->{headers}{'content-type'}, etag => $etag || undef };
}

sub Put {
  my ($Self, $path, $bytes, %o) = @_;
  my %h = ('Content-Type' => $o{type} || 'application/octet-stream');
  $h{'If-Match'} = qq{"$o{if_match}"} if $o{if_match};
  $h{'If-None-Match'} = '*' if $o{if_none_match};
  my $res = $Self->Raw('PUT', $path, $bytes, %h);
  (my $etag = $res->{headers}{etag} // '') =~ s/^(?:W\/)?"|"$//g;
  return { status => $res->{status}, etag => $etag || undef };
}

sub Mkcol  { $_[0]->Raw('MKCOL', "$_[1]/")->{status} }
sub Delete { $_[0]->Raw('DELETE', $_[1])->{status} }
sub _dest  { my ($Self, $path) = @_; return $Self->request_url($path) }
sub Move {
  my ($Self, $from, $to, %o) = @_;
  return $Self->Raw('MOVE', $from, undef, Destination => $Self->_dest($to), Overwrite => ($o{overwrite} ? 'T' : 'F'))->{status};
}
sub Copy {
  my ($Self, $from, $to, %o) = @_;
  return $Self->Raw('COPY', $from, undef, Destination => $Self->_dest($to), Overwrite => ($o{overwrite} ? 'T' : 'F'), Depth => 'infinity')->{status};
}

sub _xesc { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s }

sub PropPatch {
  my ($Self, $path, $props) = @_;
  my (@set, @rm);
  for my $k (sort keys %$props) {
    if (defined $props->{$k}) { push @set, "<J:$k>" . _xesc($props->{$k}) . "</J:$k>" }
    else                      { push @rm, "<J:$k/>" }
  }
  my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:propertyupdate xmlns:D="DAV:" xmlns:J="$NS_J">}
          . (@set ? '<D:set><D:prop>' . join('', @set) . '</D:prop></D:set>' : '')
          . (@rm  ? '<D:remove><D:prop>' . join('', @rm) . '</D:prop></D:remove>' : '')
          . '</D:propertyupdate>';
  my $res = $Self->_xml('PROPPATCH', $path, $xml);
  return 0 unless $res->{status} == 207;
  return (($res->{content} // '') =~ m{<(?:\w+:)?status>HTTP/1\.1 (?!2)\d\d\d}) ? 0 : 1;
}

sub GetAcl {
  my ($Self, $path) = @_;
  my $res = $Self->_xml('PROPFIND', $path,
    qq{<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:acl/></D:prop></D:propfind>}, Depth => 0);
  return undef unless $res->{status} == 207;
  my $tree = eval { xmlToHash($res->{content}) } or return undef;
  my @aces;
  for my $resp (_list($tree->{"${D}response"})) {
    for my $ps (_list($resp->{"${D}propstat"})) {
      next unless (_text($ps->{"${D}status"}) // '') =~ / 200 /;
      my $acl = $ps->{"${D}prop"}{"${D}acl"} or next;
      for my $ace (_list($acl->{"${D}ace"})) {
        my $p = $ace->{"${D}principal"} || {};
        my $principal = $p->{"${D}href"} ? _unescape_href(_text($p->{"${D}href"})) . '/'
                      : (map { s/^\{DAV:\}//r } grep { /^\{DAV:\}/ } keys %$p)[0];
        my @grant = map { my $x = $_; map { s/^\{DAV:\}//r } grep { /^\{DAV:\}/ } keys %$x }
                    map { _list($_) } (($ace->{"${D}grant"} || {})->{"${D}privilege"});
        push @aces, { principal => $principal, grant => \@grant,
                      inherited => exists $ace->{"${D}inherited"} ? 1 : 0 };
      }
    }
  }
  return \@aces;
}

sub SetAcl {
  my ($Self, $path, $aces) = @_;
  my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n<D:acl xmlns:D="DAV:">};
  for my $ace (@$aces) {
    my $pr = $ace->{principal} =~ m{^/} ? '<D:href>' . _xesc($ace->{principal}) . '</D:href>' : "<D:$ace->{principal}/>";
    $xml .= "<D:ace><D:principal>$pr</D:principal><D:grant>"
          . join('', map { "<D:privilege><D:$_/></D:privilege>" } @{$ace->{grant}})
          . '</D:grant></D:ace>';
  }
  $xml .= '</D:acl>';
  return $Self->_xml('ACL', $path, $xml)->{status};
}

# What this server really does, found by trying it (see the spec's "Defending
# against bogus servers"): status codes alone are not trusted.
sub Probe {
  my ($Self, $root) = @_;
  my %f = (syncCollection => 0, acl => 0, deadProps => 0, etagIsContent => 0, quota => 0);
  my $name = "$root/.jmap-probe-" . lc(new_uuid_string() =~ s/-//gr);
  my $bytes = "jmap-probe\n";
  my $put = $Self->Put($name, $bytes, type => 'text/plain', if_none_match => 1);
  return \%f unless $put->{status} =~ /^2/;

  # dead properties: only if one reads back
  if ($Self->PropPatch($name, { probe => 'x' })) {
    my ($e) = grep { $_->{href} eq $name } @{ eval { $Self->PropFind($root, 1) } || [] };
    $f{deadProps} = ($e && ($e->{dead}{probe} // '') eq 'x') ? 1 : 0;
  }
  # content ETags: equal to SHA-1 of the bytes, and unchanged by a MOVE
  if (($put->{etag} // '') eq sha1_hex($bytes)) {
    my $moved = "$name-moved";
    if ($Self->Move($name, $moved) =~ /^2/) {
      my ($e) = grep { $_->{href} eq $moved } @{ eval { $Self->PropFind($root, 1) } || [] };
      $f{etagIsContent} = ($e && ($e->{etag} // '') eq $put->{etag}) ? 1 : 0;
      $name = $moved;
    }
  }
  $Self->Delete($name);

  $f{syncCollection} = $Self->SyncCollection($root, '') ? 1 : 0;
  $f{acl} = defined $Self->GetAcl("$root/") ? 1 : 0;
  my $q = $Self->_xml('PROPFIND', "$root/",
    qq{<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:quota-used-bytes/></D:prop></D:propfind>}, Depth => 0);
  $f{quota} = ($q->{status} == 207 && ($q->{content} // '') =~ m{quota-used-bytes>\d}) ? 1 : 0;
  return \%f;
}

1;
```

- [ ] **Step 4: Run the parse test**

Run: `prove -l t/webdavtalk-parse.t`
Expected: PASS. If `xmlToHash` returns a single response as a hash and multiple as an array, `_list` already copes; if a test fails on namespace keys, print `Data::Dumper` of `xmlToHash($listing)` and fix the key names in the parser — not the test.

- [ ] **Step 5: Write the live test (skips without Cyrus)**

```perl
#!/usr/bin/perl
# t/webdavtalk-live.t -- against Cyrus #drive (bin/restart-test-proxy.sh clean)
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::WebDAVTalk;
use Data::UUID::LibUUID qw(new_uuid_string);

plan skip_all => 'set CYRUS_URL to run' unless $ENV{CYRUS_URL};
my $user = $ENV{CYRUS_USER} || 'user1';
my $dav = JMAP::Sync::WebDAVTalk->new(user => $user, password => $ENV{CYRUS_PASS} || 'x',
                                      url => "$ENV{CYRUS_URL}/dav/drive/user/$user/");
my $root = "/dav/drive/user/$user";
my $dir = "$root/t-" . lc(new_uuid_string() =~ s/-//gr);

is($dav->Mkcol($dir), 201, 'MKCOL');
my $name = "$dir/a b%#caf\x{e9}.txt";
my $put = $dav->Put($name, "hello", type => 'text/plain', if_none_match => 1);
is($put->{status}, 201, 'PUT with a name needing escapes');
is($dav->Put($name, "again", if_none_match => 1)->{status}, 412, 'If-None-Match: * on an existing file is 412');

my $list = $dav->PropFind($dir, 1);
my ($f) = grep { $_->{href} eq $name } @$list;
ok($f, 'listing round-trips the escaped name') or diag explain $list;
is($f->{size}, 5, 'size');

is($dav->Get($name, if_match => 'nope')->{status}, 412, 'If-Match mismatch is 412');
is($dav->Get($name, if_match => $f->{etag})->{content}, 'hello', 'GET with If-Match');

is($dav->Move($name, "$dir/moved.txt"), 201, 'MOVE');
is($dav->Move("$dir/moved.txt", "$dir/moved.txt", overwrite => 0) =~ /^[45]/ ? 1 : 0, 1, 'MOVE onto itself is refused');

my $sync = $dav->SyncCollection($dir, '');
ok($sync && $sync->{token}, 'sync-collection at level 1 gives a token');

my $f2 = $dav->Probe($root);
ok(!$f2->{deadProps}, 'Cyrus: dead properties are detected as NOT stored') or diag explain $f2;
ok(!$f2->{etagIsContent}, 'Cyrus: ETags are not move-stable content hashes');
ok($f2->{syncCollection}, 'Cyrus: sync-collection');
ok($f2->{acl}, 'Cyrus: ACL');

$dav->Raw('DELETE', "$dir/");
done_testing;
```

- [ ] **Step 6: Run it**

Run: `CYRUS_URL=http://localhost:8080 CYRUS_USER=user1 CYRUS_PASS=password prove -l t/webdavtalk-live.t`
Expected: PASS (requires Task 1's stack).

- [ ] **Step 7: Commit**

```bash
git add JMAP/Sync/WebDAVTalk.pm t/webdavtalk-parse.t t/webdavtalk-live.t
git commit -m "files: WebDAVTalk, a WebDAV client that probes rather than trusts"
```

---

### Task 3: `JMAP::FileNode` — ids, blob ids, name rules, globs, rights

**Files:**
- Create: `JMAP/FileNode.pm`
- Test: `t/filenode-pure.t`

**Interfaces:**
- Produces (all plain functions in package `JMAP::FileNode`):
  - `local_id() -> 'L' . 32 hex`
  - `server_id($stable) -> 'S' . first 32 hex of sha1_hex($stable)`
  - `blob_id($nodeid, $etag) -> "d-$nodeid-" . first 16 hex of sha1_hex($etag)`
  - `parse_blob_id($blobId) -> ($nodeid, $etaghash)` or `()`
  - `%CAPS` — the capability values from Global Constraints (without `webWriteUrlTemplate`)
  - `name_problem($name) -> undef | 'reason'`
  - `glob_regex($glob) -> qr/.../i`
  - `rights($privs, $parent_privs) -> { mayRead, mayAddChildren, mayRename, mayDelete, mayModifyContent, mayShare }` (JSON booleans); `$privs`/`$parent_privs` are arrayrefs of DAV privilege names, or `undef` meaning "server reported none" (all rights).
  - `utc($epoch) -> 'YYYY-MM-DDTHH:MM:SSZ'|undef`; `epoch($utc) -> int|undef`

- [ ] **Step 1: Write the failing test**

```perl
#!/usr/bin/perl
# t/filenode-pure.t
use strict;
use warnings;
use utf8;
use Test::More;
use JSON;
use lib '.';
use JMAP::FileNode;

like(JMAP::FileNode::local_id(), qr/^L[0-9a-f]{32}$/, 'local ids are L + 32 hex');
isnt(JMAP::FileNode::local_id(), JMAP::FileNode::local_id(), 'and unique');
is(JMAP::FileNode::server_id('00001234ocabc'), 'S' . substr(Digest::SHA::sha1_hex('00001234ocabc'), 0, 32), 'server ids are S + hash');

my $b = JMAP::FileNode::blob_id('Labc', '"etag-1"');
like($b, qr/^d-Labc-[0-9a-f]{16}$/, 'blob id shape');
isnt($b, JMAP::FileNode::blob_id('Labc', '"etag-2"'), 'a new etag is a new blob');
is_deeply([ JMAP::FileNode::parse_blob_id($b) ], [ 'Labc', substr($b, -16) ], 'parse');
is_deeply([ JMAP::FileNode::parse_blob_id('f-12') ], [], 'other blob kinds are not ours');

my $np = \&JMAP::FileNode::name_problem;
ok(!$np->('report.pdf'), 'plain name');
ok(!$np->('café [2].txt'), 'unicode, spaces and brackets are fine');
ok($np->(''), 'empty');
ok($np->('a/b'), 'slash');
ok($np->('.'), 'dot');
ok($np->('..'), 'dotdot');
ok($np->("a\x{0}b"), 'control character');
ok($np->('é' x 128), 'over 255 UTF-8 octets');
ok(!$np->('é' x 127), '254 octets is fine');

my $re = JMAP::FileNode::glob_regex('*.TXT');
ok('notes.txt' =~ $re, 'glob is case-insensitive');
ok('notes.txt.bak' !~ $re, 'glob is anchored');
ok('a1' =~ JMAP::FileNode::glob_regex('a?'), '?');
ok('b' =~ JMAP::FileNode::glob_regex('[abc]'), 'set');
ok('d' !~ JMAP::FileNode::glob_regex('[!abc]'), 'negated set (!)');
ok('d' =~ JMAP::FileNode::glob_regex('[^abc]'), 'negated set (^)');
ok('q' =~ JMAP::FileNode::glob_regex('[a-z]'), 'range');
ok('a.b' =~ JMAP::FileNode::glob_regex('a.b') && 'axb' !~ JMAP::FileNode::glob_regex('a.b'), 'dot is literal');

my $r = JMAP::FileNode::rights([qw(read write-content bind write-acl)], [qw(unbind bind)]);
ok($r->{mayRead} && $r->{mayModifyContent} && $r->{mayAddChildren} && $r->{mayShare}, 'mapped rights');
ok($r->{mayDelete} && $r->{mayRename}, 'delete and rename need unbind on the parent');
ok(!JMAP::FileNode::rights([qw(read)], [qw(read)])->{mayDelete}, 'no unbind, no delete');
ok(JMAP::FileNode::rights(undef, undef)->{mayShare}, 'no privilege set reported: all rights');
ok(JMAP::FileNode::rights([qw(all)], [])->{mayModifyContent}, 'DAV:all implies everything');
ok(JMAP::FileNode::rights([qw(write)], [qw(write)])->{mayDelete}, 'DAV:write includes bind/unbind/write-content');

is(JMAP::FileNode::utc(0), '1970-01-01T00:00:00Z', 'utc');
is(JMAP::FileNode::epoch('2026-10-10T01:45:31Z'), 1791596731, 'epoch');
is(JMAP::FileNode::epoch('nonsense'), undef, 'bad date');

done_testing;
```

- [ ] **Step 2: Run it to see it fail**

Run: `prove -l t/filenode-pure.t` — expected FAIL (`Can't locate JMAP/FileNode.pm`).

- [ ] **Step 3: Implement the first part of the module**

```perl
package JMAP::FileNode;

# Pure logic for FileNode over WebDAV (draft-ietf-jmap-filenode): ids, blob
# ids, name rules, globs, rights, reconciliation, set ordering, filters and
# sorts.  No I/O, no DB -- like JMAP::Dispatch and JMAP::Collation.

use strict;
use warnings;
use JSON;
use Encode qw(encode_utf8);
use Digest::SHA qw(sha1_hex);
use Data::UUID::LibUUID qw(new_uuid_string);
use POSIX qw(strftime);
use Time::Local qw(timegm);

our %CAPS = (
  maxFileNodeDepth          => undef,
  maxSizeFileNodeName       => 255,
  forbiddenNameChars        => '/',
  forbiddenNodeNames        => ['.', '..'],
  caseInsensitiveNames      => JSON::false,
  mayCreateTopLevelFileNode => JSON::false,
  fileNodeQuerySortOptions  => [qw(name type size created modified accessed nodeType tree)],
  webTrashUrl               => undef,
  webUrlTemplate            => undef,
);

sub local_id  { return 'L' . lc(new_uuid_string() =~ s/-//gr) }
sub server_id { return 'S' . substr(sha1_hex(encode_utf8($_[0])), 0, 32) }

sub blob_id { my ($nodeid, $etag) = @_; return "d-$nodeid-" . substr(sha1_hex(encode_utf8($etag // '')), 0, 16) }
sub parse_blob_id { return ($_[0] // '') =~ /^d-([LS][0-9a-f]{32}|[LS]\w+)-([0-9a-f]{16})$/ ? ($1, $2) : () }

# draft S3.1 "name" and the capability: non-empty, <= 255 UTF-8 octets, no
# forbidden characters or names, no control characters.
sub name_problem {
  my $name = shift;
  return 'name must be a non-empty string' unless defined $name && !ref $name && length $name;
  return 'name is longer than maxSizeFileNodeName' if length(encode_utf8($name)) > $CAPS{maxSizeFileNodeName};
  my $chars = quotemeta $CAPS{forbiddenNameChars};
  return 'name contains a forbidden character' if $name =~ /[$chars]/;
  return 'name contains a control character' if $name =~ /[\x00-\x1f\x7f]/;
  return 'name is forbidden' if grep { lc $_ eq lc $name } @{ $CAPS{forbiddenNodeNames} };
  return undef;
}

# draft S3.2.5 nameMatch: * ? [set] [!set] [^set], anchored, case-insensitive.
sub glob_regex {
  my $glob = shift // '';
  my $re = '';
  while (length $glob) {
    if    ($glob =~ s/^\*//)                { $re .= '.*' }
    elsif ($glob =~ s/^\?//)                { $re .= '.' }
    elsif ($glob =~ s/^\[([!^]?)([^\]]+)\]//) {
      my ($neg, $set) = ($1, $2);
      $set =~ s/([\\\]\[^])/\\$1/g;
      $re .= '[' . ($neg ? '^' : '') . $set . ']';
    }
    else { $glob =~ s/^(.)//s; $re .= quotemeta $1 }
  }
  return qr/^$re$/si;
}

# RFC 3744 privileges -> draft S3.1 FilesRights.  DAV:all and DAV:write are
# aggregates.  Deleting or moving a node is an unbind on its parent.
sub _expand {
  my $privs = shift;
  my %p = map { $_ => 1 } @$privs;
  @p{qw(read write write-content write-properties bind unbind write-acl read-acl)} = (1) x 8 if $p{all};
  @p{qw(write-content write-properties bind unbind)} = (1) x 4 if $p{write};
  return \%p;
}
sub rights {
  my ($privs, $parent) = @_;
  return { map { $_ => JSON::true } qw(mayRead mayAddChildren mayRename mayDelete mayModifyContent mayShare) }
    unless defined $privs;
  my $p  = _expand($privs);
  my $pp = defined $parent ? _expand($parent) : { unbind => 1 };
  my $b = sub { $_[0] ? JSON::true : JSON::false };
  return {
    mayRead          => $b->($p->{read}),
    mayAddChildren   => $b->($p->{bind}),
    mayRename        => $b->($pp->{unbind}),
    mayDelete        => $b->($pp->{unbind}),
    mayModifyContent => $b->($p->{'write-content'}),
    mayShare         => $b->($p->{'write-acl'}),
  };
}

sub utc { my $t = shift; return defined $t ? strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($t)) : undef }
sub epoch {
  my $s = shift // '';
  return undef unless $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z$/;
  return eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
}

1;
```

- [ ] **Step 4: Run the test**

Run: `prove -l t/filenode-pure.t` — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add JMAP/FileNode.pm t/filenode-pure.t
git commit -m "files: pure FileNode helpers -- ids, blob ids, names, globs, rights"
```

---

### Task 4: `JMAP::FileNode::reconcile` — matching a fresh listing to the mirror

**Files:**
- Modify: `JMAP/FileNode.pm`
- Test: `t/filenode-reconcile.t`

**Interfaces:**
- Consumes: entries as produced by `parse_multistatus` (Task 2); `server_id`, `local_id` (Task 3).
- Produces: `reconcile(\@mirror, \@listing, \%features) -> { create => [$entry...], update => [[$row, $entry]...], destroy => [$row...] }`.
  - `@mirror`: active rows from `jfilenodes` (hashrefs with at least `nodeid href nodetype etag size modified fileid fingerprint`).
  - `@listing`: every entry of a complete walk (missing entries excluded).
  - `%features`: `{ etagIsContent => 0|1 }`.
  - Each `create` entry gets `$entry->{nodeid}` assigned (`server_id($fileid)` when `fileid`, else `local_id()`).
  - A matched row stays the same node (id kept); `update` includes moves (href changed), content/metadata changes and privilege changes; rows whose entry is identical in `href etag size modified type` and privileges are left out.
  - Matching order: (1) `fileid`; (2) same `href` and same `nodetype`; (3) for files only, among vanished rows and appeared entries: `sha1` equal, else (if `etagIsContent`) `etag` equal, else `size` + `modified` equal — and in every tier a match is accepted only when it is unique on both sides.

- [ ] **Step 1: Write the failing test**

```perl
#!/usr/bin/perl
# t/filenode-reconcile.t
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::FileNode;

my $rec = \&JMAP::FileNode::reconcile;
my $R = '/r';
my %dir = (nodetype => 'directory');

sub row   { my %r = @_; return { nodetype => 'file', %r } }
sub entry { my %e = @_; return { isCollection => 0, %e } }

# unchanged
my $m = [ row(nodeid => 'L1', href => "$R/a", etag => 'e1', size => 1, modified => 10) ];
my $l = [ entry(href => "$R/a", etag => 'e1', size => 1, modified => 10) ];
is_deeply($rec->($m, $l, {}), { create => [], update => [], destroy => [] }, 'nothing changed');

# an ACL change elsewhere changes privileges: an update (myRights changes)
my $mp = [ row(nodeid => 'L1', href => "$R/a", etag => 'e1', size => 1, modified => 10, privs => 'read write-content') ];
my $lp = [ entry(href => "$R/a", etag => 'e1', size => 1, modified => 10, privileges => ['read']) ];
is(scalar @{ $rec->($mp, $lp, {})->{update} }, 1, 'privilege change is an update');

# content change in place
$l = [ entry(href => "$R/a", etag => 'e2', size => 2, modified => 11) ];
my $r = $rec->($m, $l, {});
is(scalar @{$r->{update}}, 1, 'changed in place is an update');
is($r->{update}[0][0]{nodeid}, 'L1', 'same node');

# Cyrus: moved by another client, ETag changed, size+mtime unique -> same id
$l = [ entry(href => "$R/sub/moved", etag => 'eX', size => 1, modified => 10) ];
$r = $rec->($m, $l, {});
is_deeply([ map { $_->[0]{nodeid} } @{$r->{update}} ], ['L1'], 'move matched by size + modified');
is($r->{update}[0][1]{href}, "$R/sub/moved", 'with its new href');
is_deeply($r->{create}, [], 'not created');
is_deeply($r->{destroy}, [], 'not destroyed');

# ambiguous size+mtime -> destroy + create, never a guess
$m = [ row(nodeid => 'L1', href => "$R/a", size => 1, modified => 10),
       row(nodeid => 'L2', href => "$R/b", size => 1, modified => 10) ];
$l = [ entry(href => "$R/x", size => 1, modified => 10), entry(href => "$R/y", size => 1, modified => 10) ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 2, 'ambiguous fingerprints: both destroyed');
is(scalar @{$r->{create}}, 2, 'and both created');
like($r->{create}[0]{nodeid}, qr/^L/, 'with local ids');

# etag only counts when the server's etags are proven content hashes
$m = [ row(nodeid => 'L1', href => "$R/a", etag => 'same', size => 1, modified => 10) ];
$l = [ entry(href => "$R/z", etag => 'same', size => 1, modified => 99) ];
is(scalar @{ $rec->($m, $l, {})->{destroy} }, 1, 'etag ignored when not content');
is(scalar @{ $rec->($m, $l, { etagIsContent => 1 })->{update} }, 1, 'etag matched when content');

# sha1 beats everything
$l = [ entry(href => "$R/z", sha1 => 'abc', size => 5, modified => 1) ];
$m = [ row(nodeid => 'L1', href => "$R/a", fingerprint => 'abc', size => 1, modified => 10) ];
is(scalar @{ $rec->($m, $l, {})->{update} }, 1, 'sha1 fingerprint matches');

# server ids: S-prefixed, and a fileid match survives any move
$m = [ row(nodeid => JMAP::FileNode::server_id('f1'), href => "$R/a", fileid => 'f1') ];
$l = [ entry(href => "$R/q/w", fileid => 'f1', size => 7, modified => 70) ];
$r = $rec->($m, $l, {});
is($r->{update}[0][0]{nodeid}, JMAP::FileNode::server_id('f1'), 'fileid match');
$r = $rec->([], [ entry(href => "$R/new", fileid => 'f9') ], {});
is($r->{create}[0]{nodeid}, JMAP::FileNode::server_id('f9'), 'new node with a fileid gets an S id');

# a directory is never matched by fingerprint, and type changes are not "same href"
$m = [ row(nodeid => 'L1', href => "$R/d", %dir) ];
$l = [ entry(href => "$R/d", isCollection => 0, size => 1, modified => 1) ];
$r = $rec->($m, $l, {});
is(scalar @{$r->{destroy}}, 1, 'dir replaced by a file of the same name: destroy');
is(scalar @{$r->{create}}, 1, 'and create');

done_testing;
```

- [ ] **Step 2: Run it to see it fail**

Run: `prove -l t/filenode-reconcile.t` — expected FAIL (`Undefined subroutine &JMAP::FileNode::reconcile`).

- [ ] **Step 3: Implement `reconcile` (append to `JMAP/FileNode.pm` before `1;`)**

```perl
# Match a complete fresh listing against the mirror (spec "Ids" and
# "Defending against bogus servers").  A fingerprint match is only accepted
# when it is unique on both sides.
sub reconcile {
  my ($mirror, $listing, $features) = @_;
  $features ||= {};
  my (%row_used, %entry_used, @update);
  my $type_of = sub { $_[0]{isCollection} ? 'directory' : 'file' };
  # privileges count: a changed ACL changes the derived myRights (draft "Access Control")
  my $changed = sub {
    my ($row, $e) = @_;
    my $eprivs = defined $e->{privileges} ? join(' ', @{$e->{privileges}}) : undef;
    return 1 if ($row->{privs} // '') ne ($eprivs // '');
    return grep { ($row->{$_} // '') ne ($e->{$_} // '') } qw(href etag size modified type);
  };
  my $pair = sub {
    my ($row, $e) = @_;
    $row_used{$row->{nodeid}} = $entry_used{$e->{href}} = 1;
    push @update, [$row, $e] if $changed->($row, $e);
  };

  # 1. server stable ids
  my %row_by_fileid = map { $_->{fileid} => $_ } grep { defined $_->{fileid} } @$mirror;
  for my $e (grep { defined $_->{fileid} } @$listing) {
    my $row = $row_by_fileid{$e->{fileid}} or next;
    $pair->($row, $e);
  }
  # 2. same path, same kind
  my %row_by_href = map { $_->{href} => $_ } grep { !$row_used{$_->{nodeid}} } @$mirror;
  for my $e (grep { !$entry_used{$_->{href}} } @$listing) {
    my $row = $row_by_href{$e->{href}} or next;
    next if $row_used{$row->{nodeid}} || $row->{nodetype} ne $type_of->($e);
    $pair->($row, $e);
  }
  # 3. files only: fingerprints, strongest first, unique on both sides
  my @tiers = (
    [ sub { $_[0]{fingerprint} }, sub { $_[0]{sha1} } ],
    ($features->{etagIsContent} ? [ sub { $_[0]{etag} }, sub { $_[0]{etag} } ] : ()),
    [ sub { defined $_[0]{size} && defined $_[0]{modified} ? "$_[0]{size}/$_[0]{modified}" : undef },
      sub { defined $_[0]{size} && defined $_[0]{modified} ? "$_[0]{size}/$_[0]{modified}" : undef } ],
  );
  for my $tier (@tiers) {
    my ($rk, $ek) = @$tier;
    my (%rows, %entries);
    push @{ $rows{ $rk->($_) // next } }, $_
      for grep { !$row_used{$_->{nodeid}} && $_->{nodetype} eq 'file' } @$mirror;
    push @{ $entries{ $ek->($_) // next } }, $_
      for grep { !$entry_used{$_->{href}} && !$_->{isCollection} } @$listing;
    for my $k (keys %rows) {
      next unless @{$rows{$k}} == 1 && @{ $entries{$k} || [] } == 1;
      $pair->($rows{$k}[0], $entries{$k}[0]);
    }
  }

  my @create = map { $_->{nodeid} = defined $_->{fileid} ? server_id($_->{fileid}) : local_id(); $_ }
               grep { !$entry_used{$_->{href}} } @$listing;
  my @destroy = grep { !$row_used{$_->{nodeid}} } @$mirror;
  return { create => \@create, update => \@update, destroy => \@destroy };
}
```

- [ ] **Step 4: Run the test**

Run: `prove -l t/filenode-reconcile.t` — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add JMAP/FileNode.pm t/filenode-reconcile.t
git commit -m "files: reconcile a WebDAV listing with the mirror, ids surviving moves"
```

---

### Task 5: Sync, `FileNode/get`, `FileNode/changes`, capability; remove StorageNode

**Files:**
- Modify: `JMAP/Sync/Common.pm` (connection + backend commands)
- Modify: `JMAP/ImapDB.pm` (`sync_files`, `sync_files_if_due`, `_filenode_row_from_entry`, `files_root`, `filenode_features`)
- Create: `JMAP/API/FileNode.pm`
- Delete: `JMAP/API/StorageNode.pm`
- Modify: `JMAP/API.pm` (`require JMAP::API::FileNode;` instead of `StorageNode`)
- Modify: `JMAP/Dispatch.pm` (method table)
- Modify: `JMAP/Capabilities.pm`, `bin/jmap-proxy.pl` (session, `sync` command, `firstsync`)
- Test: `t/filenode-webdav.t` (integration; grows in later tasks), `t/dispatch-method-capability.t` (existing)

**Interfaces:**
- Consumes: `JMAP::Sync::WebDAVTalk` (Task 2), `JMAP::FileNode::reconcile/rights/utc/blob_id` (Tasks 3-4), schema (Task 1).
- Produces:
  - `JMAP::Sync::Common::connect_files() -> JMAP::Sync::WebDAVTalk|undef`, and backend commands `files_propfind($path, $depth)`, `files_sync($path, $token)`, `files_probe($root)`, `files_raw($method, $path, $body, %h)`, `files_get($path, %o)`, `files_put($path, $bytes, %o)`, `files_mkcol($path)`, `files_move($from, $to, %o)`, `files_copy($from, $to, %o)`, `files_delete($path)`, `files_proppatch($path, \%props)`, `files_getacl($path)`, `files_setacl($path, \@aces)` — each a thin pass-through to the WebDAVTalk method of the same name.
  - `ImapDB::files_root() -> '/abs/root/path'|undef` (from `iserver.webdavURL`).
  - `ImapDB::filenode_features() -> \%features` (probed once, cached in `iserver.webdavFeatures`).
  - `ImapDB::sync_files() -> 1` and `ImapDB::sync_files_if_due($maxage)`.
  - `ImapDB::filenode_rows() -> [active rows]`, `ImapDB::filenode_row($nodeid) -> row|undef`.
  - `$api->_filenode_object($row, \%rows_by_id) -> FileNode hashref` (method on `JMAP::API`; used by get/set/copy/query).

- [ ] **Step 1: Write the failing integration test**

```perl
#!/usr/bin/perl
# t/filenode-webdav.t -- FileNode against Cyrus #drive through the proxy.
# Needs: bin/restart-test-proxy.sh clean (IMAP mode).
use strict;
use warnings;
use Test::More;
use JSON;
use HTTP::Tiny;
use lib '.';
use JMAP::Sync::WebDAVTalk;
use Data::UUID::LibUUID qw(new_uuid_string);

plan skip_all => 'set CYRUS_URL and JMAP_PROXY_URL' unless $ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL};
my $user = $ENV{CYRUS_USER} || 'user1';
my $http = HTTP::Tiny->new;
my $auth = 'Basic ' . MIME::Base64::encode_base64("$user:password", '');
my @using = ('urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:filenode');

sub jmap {
  my @calls = @_;
  my $res = $http->post("$ENV{JMAP_PROXY_URL}/jmap/", {
    headers => { Authorization => $auth, 'Content-Type' => 'application/json' },
    content => encode_json({ using => \@using,
      methodCalls => [ map { [ $_->[0], { accountId => $user, %{$_->[1]} }, "c$_->[2]" ] }
                       map { [ @{$calls[$_]}, $_ ] } 0 .. $#calls ] }),
  });
  die "HTTP $res->{status}: $res->{content}" unless $res->{success};
  return [ map { $_->[1] } @{ decode_json($res->{content})->{methodResponses} } ];
}

my $dav = JMAP::Sync::WebDAVTalk->new(user => $user, password => 'x',
                                      url => "$ENV{CYRUS_URL}/dav/drive/user/$user/");
my $root = "/dav/drive/user/$user";
my $tag = 't' . lc(substr(new_uuid_string() =~ s/-//gr, 0, 8));

# session advertises the capability
my $sess = decode_json($http->get("$ENV{JMAP_PROXY_URL}/.well-known/jmap", { headers => { Authorization => $auth } })->{content});
ok($sess->{capabilities}{'urn:ietf:params:jmap:filenode'}, 'session capability');
is_deeply($sess->{capabilities}{'urn:ietf:params:jmap:filenode'}, {}, 'and it is an empty object');
my $acap = $sess->{accounts}{$user}{accountCapabilities}{'urn:ietf:params:jmap:filenode'};
is($acap->{maxSizeFileNodeName}, 255, 'account capability');

# the root
my ($q) = @{ jmap(['FileNode/query', { filter => { isTopLevel => JSON::true } }]) };
is(scalar @{$q->{ids}}, 1, 'one top-level node');
my ($g) = @{ jmap(['FileNode/get', { ids => $q->{ids} }]) };
my $home = $g->{list}[0];
is($home->{role}, 'home', 'root has role home');
is($home->{parentId}, undef, 'root parentId is null');
is($home->{nodeType}, 'directory', 'root is a directory');
my $state = $g->{state};

# changes made behind the proxy's back show up
$dav->Mkcol("$root/$tag");
$dav->Put("$root/$tag/one.txt", "1", type => 'text/plain');
my ($c) = @{ jmap(['FileNode/changes', { sinceState => $state }]) };
is(scalar @{$c->{created}}, 2, 'external MKCOL + PUT are two creations') or diag explain $c;
my ($g2) = @{ jmap(['FileNode/get', { ids => $c->{created} }]) };
my ($file) = grep { $_->{name} eq 'one.txt' } @{$g2->{list}};
my ($dir)  = grep { $_->{name} eq $tag } @{$g2->{list}};
is($file->{parentId}, $dir->{id}, 'parent linkage');
is($file->{size}, 1, 'size');
like($file->{blobId}, qr/^d-/, 'blobId');
like($file->{id}, qr/^[LS]/, 'id prefix');

# an external move keeps the id (Cyrus: size + getlastmodified)
$state = $c->{newState};
$dav->Move("$root/$tag/one.txt", "$root/$tag/renamed.txt");
($c) = @{ jmap(['FileNode/changes', { sinceState => $state }]) };
is_deeply($c->{updated}, [ $file->{id} ], 'external move is an update of the same node') or diag explain $c;
is_deeply($c->{created}, [], 'not a creation');

# fetchParents
my ($fp) = @{ jmap(['FileNode/get', { ids => [ $file->{id} ], fetchParents => JSON::true, properties => ['name', 'parentId'] }]) };
is_deeply([ sort map { $_->{id} } @{$fp->{list}} ], [ sort $file->{id}, $dir->{id}, $home->{id} ], 'fetchParents');

$dav->Raw('DELETE', "$root/$tag/");
done_testing;
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/restart-test-proxy.sh clean > /tmp/rt.log 2>&1; CYRUS_URL=http://localhost:8080 JMAP_PROXY_URL=http://localhost:9000 prove -l t/filenode-webdav.t`
Expected: FAIL — no `urn:ietf:params:jmap:filenode` capability.

- [ ] **Step 3: Backend connection and commands in `JMAP/Sync/Common.pm`**

Next to `_caldav_url`/`_carddav_url`:

```perl
sub _webdav_url { $_[0]->{auth}{webdavURL} }
```

Next to `connect_contacts`:

```perl
sub connect_files {
  my $Self = shift;
  my $url  = $Self->_webdav_url() or return;
  if ($Self->{files}) {
    $Self->{lastused} = time();
    return $Self->{files};
  }
  require JMAP::Sync::WebDAVTalk;
  $Self->{files} = JMAP::Sync::WebDAVTalk->new(
    user => $Self->{auth}{username},
    $Self->_dav_auth(),
    url  => $url,
  );
  $Self->{lastused} = time();
  return $Self->{files};
}

# FileNode backend commands: thin pass-throughs, so ImapDB never holds a
# WebDAV connection itself (the same split as calendars and contacts).
for my $m (qw(PropFind SyncCollection Probe Raw Get Put Mkcol Move Copy Delete PropPatch GetAcl SetAcl)) {
  my $cmd = 'files_' . lc($m =~ s/(?<!^)([A-Z])/_$1/gr);
  no strict 'refs';
  *$cmd = sub { my $Self = shift; my $dav = $Self->connect_files() or die "no WebDAV URL\n"; return $dav->$m(@_) };
}
```

This defines `files_prop_find`, `files_sync_collection`, `files_probe`, `files_raw`, `files_get`, `files_put`, `files_mkcol`, `files_move`, `files_copy`, `files_delete`, `files_prop_patch`, `files_get_acl`, `files_set_acl`. Use exactly these names from ImapDB.

- [ ] **Step 4: Sync in `JMAP/ImapDB.pm`**

Add near the other `sync_*` functions:

```perl
use JMAP::FileNode;

# The FileNode root: the path of the account's webdavURL, or undef.
sub files_root {
  my $Self = shift;
  $Self->begin();
  my $url = $Self->dgetfield('iserver', {}, 'webdavURL');
  $Self->commit();
  return undef unless $url;
  (my $path = $url) =~ s{^https?://[^/]+}{};
  $path = URI::Escape::uri_unescape($path);
  $path =~ s{/+$}{};
  return $path;
}

# What the server really supports (Probe), worked out once per account.
sub filenode_features {
  my $Self = shift;
  return $Self->{_filefeatures} if $Self->{_filefeatures};
  $Self->begin();
  my $json = $Self->dgetfield('iserver', {}, 'webdavFeatures');
  $Self->commit();
  my $f = $json ? decode_json($json) : undef;
  unless ($f) {
    my $root = $Self->files_root() or return {};
    $f = eval { $Self->backend_cmd('files_probe', $root) } || {};
    $Self->begin();
    $Self->dupdate('iserver', { webdavFeatures => encode_json($f) });
    $Self->commit();
  }
  return $Self->{_filefeatures} = $f;
}

sub filenode_rows {
  my $Self = shift;
  return $Self->dget('jfilenodes', { active => 1 });
}

sub filenode_row {
  my ($Self, $nodeid) = @_;
  return $Self->dgetone('jfilenodes', { nodeid => $nodeid, active => 1 });
}

# One mirror row's columns from a listing entry.
sub _filenode_cols {
  my ($e) = @_;
  my $name = $e->{href} =~ m{([^/]+)$} ? $1 : $e->{href};
  return (
    href        => $e->{href},
    name        => $name,
    nodetype    => $e->{isCollection} ? 'directory' : 'file',
    etag        => $e->{etag},
    ctag        => $e->{ctag},
    size        => $e->{isCollection} ? undef : ($e->{size} // 0),
    type        => $e->{isCollection} ? undef : ($e->{type} || 'application/octet-stream'),
    created     => JMAP::FileNode::epoch($e->{dead}{created}) // $e->{created} // $e->{modified},
    modified    => JMAP::FileNode::epoch($e->{dead}{modified}) // $e->{modified},
    fileid      => $e->{fileid},
    fingerprint => $e->{sha1},
    privs       => defined $e->{privileges} ? join(' ', @{$e->{privileges}}) : undef,
    (defined $e->{dead}{executable}   ? (executable   => $e->{dead}{executable} ? 1 : 0) : ()),
    (defined $e->{dead}{isSubscribed} ? (isSubscribed => $e->{dead}{isSubscribed} ? 1 : 0) : ()),
    (defined $e->{dead}{accessed}     ? (accessed     => JMAP::FileNode::epoch($e->{dead}{accessed})) : ()),
  );
}

# Walk the whole tree, one collection at a time (spec "Sync"): sync-collection
# at level 1 where the server has it, PROPFIND Depth 1 otherwise, and never
# prune on an unchanged collection ETag.
sub _files_walk {
  my ($Self, $root, $features) = @_;
  my (@listing, @todo);
  my ($rootentry) = grep { $_->{href} eq $root } @{ $Self->backend_cmd('files_prop_find', "$root/", 0) };
  $rootentry ||= { href => $root, isCollection => 1 };
  $rootentry->{isCollection} = 1;
  push @listing, $rootentry;
  push @todo, $root;
  while (defined(my $dir = shift @todo)) {
    my $entries = $Self->backend_cmd('files_prop_find', "$dir/", 1);
    for my $e (@$entries) {
      next if $e->{missing} || $e->{href} eq $dir;
      next if $e->{href} =~ m{/\.jmap-probe-};
      push @listing, $e;
      push @todo, $e->{href} if $e->{isCollection};
    }
  }
  return \@listing;
}

sub sync_files {
  my $Self = shift;
  my $root = $Self->files_root() or return;
  my $features = $Self->filenode_features();
  my $listing = $Self->_files_walk($root, $features);

  $Self->begin();
  my $mirror = $Self->filenode_rows();
  my $plan = JMAP::FileNode::reconcile($mirror, $listing, $features);
  my %id_by_href = map { $_->{href} => $_->{nodeid} } @$mirror;
  $id_by_href{ $_->[1]{href} } = $_->[0]{nodeid} for @{$plan->{update}};
  $id_by_href{ $_->{href} } = $_->{nodeid} for @{$plan->{create}};
  my $parent_of = sub {
    my $href = shift;
    return undef if $href eq $root;
    (my $p = $href) =~ s{/[^/]+$}{};
    return $id_by_href{$p};
  };
  my $now = time();
  for my $e (@{$plan->{create}}) {
    $Self->dmake('jfilenodes', {
      nodeid => $e->{nodeid}, parentid => $parent_of->($e->{href}),
      _filenode_cols($e), changed => $now,
      role => ($e->{href} eq $root ? 'home' : undef),
      executable => 0, isSubscribed => 1,
    });
  }
  for my $u (@{$plan->{update}}) {
    my ($row, $e) = @$u;
    $Self->ddirty('jfilenodes', { parentid => $parent_of->($e->{href}), _filenode_cols($e), changed => $now },
                  { nodeid => $row->{nodeid} });
  }
  for my $row (@{$plan->{destroy}}) {
    $Self->ddirty('jfilenodes', { active => 0 }, { nodeid => $row->{nodeid} });
  }
  $Self->dupdate('iserver', { lastfilesync => $now });
  $Self->commit();
  return 1;
}

sub sync_files_if_due {
  my ($Self, $maxage) = @_;
  return unless $Self->files_root();
  $Self->begin();
  my $last = $Self->dgetfield('iserver', {}, 'lastfilesync') // 0;
  $Self->commit();
  return if time() - $last < $maxage;
  eval { $Self->sync_files(); 1 } or warn "sync_files: $@";
}
```

Add `sync_files` to the end of `firstsync`'s DAV loop: change `for my $sync (qw(sync_calendars sync_addressbooks))` to `qw(sync_calendars sync_addressbooks sync_files)`.

- [ ] **Step 5: Run `sync_files_if_due(300)` from the periodic sync**

In `bin/jmap-proxy.pl`'s worker `if ($cmd eq 'sync')` block, after `$db->sync_addressbooks();`:

```perl
        $db->sync_files_if_due(300) if $db->can('sync_files_if_due');
```

- [ ] **Step 6: `JMAP/API/FileNode.pm` — get and changes**

```perl
package JMAP::API;
use strict;
use warnings;
use JSON;
use JMAP::FileNode;

# draft-ietf-jmap-filenode S3.1: one mirror row as a FileNode object.
sub _filenode_object {
  my ($Self, $row, $byid) = @_;
  my $parent = defined $row->{parentid} ? $byid->{$row->{parentid}} : undef;
  my $privs  = defined $row->{privs} ? [ split ' ', $row->{privs} ] : undef;
  my $pprivs = $parent && defined $parent->{privs} ? [ split ' ', $parent->{privs} ] : undef;
  my $isfile = $row->{nodetype} eq 'file';
  return {
    id           => "$row->{nodeid}",
    parentId     => (defined $row->{parentid} ? "$row->{parentid}" : undef),
    nodeType     => $row->{nodetype},
    blobId       => $isfile ? JMAP::FileNode::blob_id($row->{nodeid}, $row->{etag}) : undef,
    target       => undef,
    size         => $isfile ? 0 + ($row->{size} // 0) : undef,
    name         => $row->{name},
    type         => $isfile ? $row->{type} : undef,
    created      => JMAP::FileNode::utc($row->{created}),
    modified     => JMAP::FileNode::utc($row->{modified}),
    accessed     => JMAP::FileNode::utc($row->{accessed} // $row->{modified}),
    changed      => JMAP::FileNode::utc($row->{changed}),
    executable   => $row->{executable} ? JSON::true : JSON::false,
    isSubscribed => (($row->{isSubscribed} // 1) ? JSON::true : JSON::false),
    myRights     => JMAP::FileNode::rights($privs, $parent ? $pprivs : undef),
    shareWith    => undef,
    role         => $row->{role},
  };
}

sub _filenode_init {
  my ($Self, $args, $maxage) = @_;
  $Self->{db}->sync_files_if_due($maxage // 60);
  return $Self->_api_init($args);
}

sub api_FileNode_get {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my $rows = $Self->{db}->filenode_rows();
  my %byid = map { $_->{nodeid} => $_ } @$rows;

  my @want = $args->{ids} ? map { $Self->idmap($_) } @{$args->{ids}} : map { $_->{nodeid} } @$rows;
  my (%seen, @list, @notfound);
  for my $id (@want) {
    next if $seen{$id}++;
    my $row = $byid{$id} or do { push @notfound, $id; next };
    push @list, $row;
  }
  # draft S3.2.1 fetchParents: every ancestor, once
  if ($args->{fetchParents}) {
    for my $row (@list) {
      my $p = $row->{parentid};
      while (defined $p && !$seen{$p}++) {
        my $prow = $byid{$p} or last;
        push @list, $prow;
        $p = $prow->{parentid};
      }
    }
  }
  # state after data (as hm does), so the state is never newer than the list
  my $state = "$user->{jstateFileNode}";
  $Self->commit();

  my @objs = map { $Self->_filenode_object($_, \%byid) } @list;
  if ($args->{properties}) {
    my %want = map { $_ => 1 } 'id', @{$args->{properties}};
    @objs = map { my $o = $_; +{ map { ($_ => $o->{$_}) } grep { $want{$_} } keys %$o } } @objs;
  }
  return ['FileNode/get', { accountId => $accountid, state => $state,
                            list => \@objs, notFound => [ map { "$_" } @notfound ] }];
}

sub api_FileNode_changes {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my $newState = "$user->{jstateFileNode}";
  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;
  my $data = $Self->{db}->dget('jfilenodes', { jmodseq => ['>', $args->{sinceState}] },
                               'nodeid,active,jcreated,jmodseq');
  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless defined $data;
  $Self->commit();
  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'nodeid');
  return ['FileNode/changes', {
    accountId => $accountid, oldState => "$args->{sinceState}", newState => $newState,
    hasMoreChanges => ($partial ? JSON::true : JSON::false),
    created => $created, updated => $updated, destroyed => $destroyed,
  }];
}

1;
```

(`_check_since_state`, `_limit_changes` and `_classify_changes` already exist and are used by `api_Email_changes`; read their signatures in `JMAP/API/Email.pm`/`JMAP/API.pm` before relying on them.)

- [ ] **Step 7: Wire it up and remove StorageNode**

```bash
git rm JMAP/API/StorageNode.pm
```

In `JMAP/API.pm` replace `require JMAP::API::StorageNode;` with `require JMAP::API::FileNode;`.

In `JMAP/Dispatch.pm` replace the filenode entry with:

```perl
    # draft-ietf-jmap-filenode
    'urn:ietf:params:jmap:filenode' => [qw(
      FileNode/get FileNode/changes FileNode/set FileNode/copy
      FileNode/query FileNode/queryChanges
    )],
```

(Later tasks add the subs for set/copy/query/queryChanges; until then `t/dispatch-method-capability.t` may report them missing — if it does, list only `FileNode/get FileNode/changes` now and add each method in the task that implements it.)

In `JMAP/Capabilities.pm`, after the contacts block:

```perl
    ($conf->{webdavURL} ? ('urn:ietf:params:jmap:filenode' => {
      %JMAP::FileNode::CAPS,
      webWriteUrlTemplate => ($conf->{baseurl} ? "$conf->{baseurl}/filenode/{accountId}/{id}" : undef),
    }) : ()),
```

with `require JMAP::FileNode;` at the top. In `bin/jmap-proxy.pl`, where `imap_account_capabilities($a)` is called for the session, pass `{ %$a, baseurl => $BASEURL }`, and add `$primary_for{'urn:ietf:params:jmap:filenode'} //= $aid if $a->{webdavURL};`. The existing `$top_caps{$_} //= {}` line already gives the empty session-level object.

- [ ] **Step 8: Run the tests**

Run: `prove -l t/ && bin/restart-test-proxy.sh clean > /tmp/rt.log 2>&1 && CYRUS_URL=http://localhost:8080 JMAP_PROXY_URL=http://localhost:9000 prove -l t/filenode-webdav.t`
Expected: PASS. `grep -h '^sub api_' JMAP/API/*.pm | sort | uniq -d` prints nothing.

- [ ] **Step 9: Commit**

```bash
git add -A JMAP/ bin/jmap-proxy.pl t/filenode-webdav.t
git commit -m "files: sync the WebDAV tree into a mirror; FileNode/get and /changes

Replaces the fake StorageNode data."
```

---

### Task 6: Set ordering and FileNode/set create and destroy

**Files:**
- Modify: `JMAP/FileNode.pm` (`order_creates`, `unique_name`)
- Modify: `JMAP/ImapDB.pm` (`create_filenodes`, `destroy_filenodes`, `_files_refresh_dir`, `_filenode_dead_set`)
- Modify: `JMAP/API/FileNode.pm` (`api_FileNode_set`, create + destroy parts)
- Test: `t/filenode-order.t` (unit), `t/filenode-webdav.t` (extend)

**Interfaces:**
- Consumes: Tasks 2-5.
- Produces:
  - `JMAP::FileNode::order_creates(\%create) -> [cid...]` — creation ids ordered so a `#cid` parentId comes after `cid`; cycles among `#` refs leave the remaining cids at the end (they then fail with `invalidProperties` on `parentId`).
  - `JMAP::FileNode::unique_name($name, \%taken_lc_or_exact) -> $name` — `name[2].ext`, `name[3].ext`, … (the extension is the part after the last `.` when that is not the first character).
  - `ImapDB::create_filenodes(\%create, $idmap, \%opts) -> (\%created, \%notCreated, \@alsoDestroyed)` where `%opts = (onExists => undef|'replace'|'rename'|'newest', onDestroyRemoveChildren => 0|1, ci => 0|1)`.
  - `ImapDB::destroy_filenodes(\@ids, \%opts) -> (\@destroyed, \%notDestroyed)`.
  - `ImapDB::_files_refresh_dir($dir_href)` — re-lists one collection (Depth 1) and updates its children's rows from the listing (create/update/destroy within that directory only), then returns `{ href => row }` for its children.

- [ ] **Step 1: Write the failing ordering test**

```perl
#!/usr/bin/perl
# t/filenode-order.t
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::FileNode;

my $oc = \&JMAP::FileNode::order_creates;
my $ord = $oc->({ c => { parentId => '#b' }, b => { parentId => '#a' }, a => { parentId => 'Lroot' } });
is_deeply($ord, [qw(a b c)], 'creates ordered by #parent references');
$ord = $oc->({ x => { parentId => '#y' }, y => { parentId => '#x' }, z => { parentId => 'Lr' } });
is($ord->[0], 'z', 'a cycle among #refs goes last');
is(scalar @$ord, 3, 'and is still listed');

my $un = \&JMAP::FileNode::unique_name;
is($un->('a.txt', { 'a.txt' => 1 }), 'a[2].txt', 'first rename');
is($un->('a.txt', { 'a.txt' => 1, 'a[2].txt' => 1 }), 'a[3].txt', 'skips taken');
is($un->('.profile', { '.profile' => 1 }), '.profile[2]', 'leading dot is not an extension');
is($un->('README', { 'README' => 1 }), 'README[2]', 'no extension');

done_testing;
```

- [ ] **Step 2: Run it** — `prove -l t/filenode-order.t`, expected FAIL (undefined subs).

- [ ] **Step 3: Implement (append to `JMAP/FileNode.pm`)**

```perl
# Creations whose parentId is "#cid" must follow cid (draft S3.2.3).
sub order_creates {
  my $create = shift;
  my (@order, %done);
  my @todo = sort keys %$create;
  my $progress = 1;
  while (@todo && $progress) {
    $progress = 0;
    my @next;
    for my $cid (@todo) {
      my $p = $create->{$cid}{parentId} // '';
      if ($p =~ /^#(.+)$/ && exists $create->{$1} && !$done{$1}) { push @next, $cid; next }
      push @order, $cid; $done{$cid} = 1; $progress = 1;
    }
    @todo = @next;
  }
  return [ @order, @todo ];
}

# draft S3.2.3 onExists "rename": a name that does not clash.
sub unique_name {
  my ($name, $taken) = @_;
  my ($base, $ext) = $name =~ /^(.+?)(\.[^.]+)?$/ && $name !~ /^\.[^.]*$/ ? ($1, $2 // '') : ($name, '');
  for my $n (2 .. 10_000) {
    my $try = "$base\[$n\]$ext";
    return $try unless $taken->{$try};
  }
  die "no free name for $name\n";
}
```

- [ ] **Step 4: Run it** — `prove -l t/filenode-order.t`, expected PASS. Commit:

```bash
git add JMAP/FileNode.pm t/filenode-order.t
git commit -m "files: order #ref creations and generate rename-on-clash names"
```

- [ ] **Step 5: Extend the integration test with create/destroy cases (failing)**

Append before `$dav->Raw('DELETE', ...)` in `t/filenode-webdav.t`:

```perl
# --- create and destroy (Task 6)
my $blob = decode_json($http->post("$ENV{JMAP_PROXY_URL}/upload/$user/", {
  headers => { Authorization => $auth, 'Content-Type' => 'text/plain' }, content => 'uploaded' })->{content});
my ($set) = @{ jmap(['FileNode/set', { create => {
  d   => { parentId => $dir->{id}, name => 'made dir' },
  sub => { parentId => '#d', name => "caf\x{e9} [2] %#?.txt", blobId => $blob->{blobId}, type => 'text/plain' },
} }]) };
ok($set->{created}{d}{id} && $set->{created}{sub}{id}, 'directory and file (with a #ref parent) created') or diag explain $set;
my $l = $dav->PropFind("$root/$tag/made dir", 1);
ok((grep { $_->{href} eq "$root/$tag/made dir/caf\x{e9} [2] %#?.txt" } @$l), 'on the server, escaped exactly once') or diag explain $l;
is($set->{created}{sub}{size}, 8, 'server-set size returned');

($set) = @{ jmap(['FileNode/set', { create => { again => { parentId => $set->{created}{d}{id}, name => "caf\x{e9} [2] %#?.txt", blobId => $blob->{blobId} } } }]) };
is($set->{notCreated}{again}{type}, 'alreadyExists', 'name clash is alreadyExists');
ok($set->{notCreated}{again}{existingId}, 'with existingId');

($set) = @{ jmap(['FileNode/set', { onExists => 'rename', create => { r => { parentId => $dir->{id}, name => 'renamed.txt', blobId => $blob->{blobId} } } }]) };
is($set->{created}{r}{name}, 'renamed[2].txt', 'onExists rename returns the new name');

($set) = @{ jmap(['FileNode/set', { create => { bad => { parentId => $dir->{id}, name => 'a/b' } } }]) };
is($set->{notCreated}{bad}{type}, 'invalidProperties', 'forbidden character');

($set) = @{ jmap(['FileNode/set', { destroy => [ $dir->{id} ] }]) };
is($set->{notDestroyed}{ $dir->{id} }{type}, 'nodeHasChildren', 'non-empty directory without onDestroyRemoveChildren');
($set) = @{ jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $dir->{id} ] }]) };
ok((grep { $_ eq $dir->{id} } @{$set->{destroyed}}) && @{$set->{destroyed}} > 1, 'destroyed with all its descendants listed') or diag explain $set;
is($dav->Raw('PROPFIND', "$root/$tag/", undef, Depth => 0)->{status}, 404, 'gone from the server');

# destroy a and create a in one call: the name is free at the end
my ($mk) = @{ jmap(['FileNode/set', { create => { a => { parentId => $home->{id}, name => "$tag-a", blobId => $blob->{blobId} } } }]) };
($set) = @{ jmap(['FileNode/set', { destroy => [ $mk->{created}{a}{id} ],
  create => { a2 => { parentId => $home->{id}, name => "$tag-a", blobId => $blob->{blobId} } } }]) };
ok($set->{created}{a2}, 'destroy-then-create of the same name in one /set') or diag explain $set;
jmap(['FileNode/set', { destroy => [ $set->{created}{a2}{id} ] }]);
```

Run: `CYRUS_URL=... JMAP_PROXY_URL=... prove -l t/filenode-webdav.t` — expected FAIL (`FileNode/set` is `unknownMethod`).

- [ ] **Step 6: Implement create/destroy in `JMAP/ImapDB.pm`**

```perl
# Re-list one directory and bring its children's rows in line (used after
# every write; a Depth-0 PROPFIND on a file is unreliable -- Cyrus returns an
# empty multistatus -- so files are always refreshed through their parent).
sub _files_refresh_dir {
  my ($Self, $dirhref) = @_;
  my $entries = $Self->backend_cmd('files_prop_find', "$dirhref/", 1);
  $Self->begin();
  my $dir = $Self->dgetone('jfilenodes', { href => $dirhref, active => 1 });
  my %rows = map { $_->{href} => $_ } @{ $Self->dget('jfilenodes', { parentid => $dir->{nodeid}, active => 1 }) };
  my %seen;
  my $now = time();
  for my $e (grep { !$_->{missing} && $_->{href} ne $dirhref } @$entries) {
    $seen{$e->{href}} = 1;
    if (my $row = $rows{$e->{href}}) {
      my %cols = _filenode_cols($e);
      $Self->ddirty('jfilenodes', { %cols, changed => $now }, { nodeid => $row->{nodeid} })
        if grep { ($row->{$_} // '') ne ($cols{$_} // '') } qw(etag size modified type privs);
    }
    else {
      $Self->dmake('jfilenodes', { nodeid => defined $e->{fileid} ? JMAP::FileNode::server_id($e->{fileid}) : JMAP::FileNode::local_id(),
        parentid => $dir->{nodeid}, _filenode_cols($e), changed => $now, executable => 0, isSubscribed => 1 });
    }
  }
  my $out = { map { $_->{href} => $_ } @{ $Self->dget('jfilenodes', { parentid => $dir->{nodeid}, active => 1 }) } };
  $Self->commit();
  return $out;
}

# Client-settable properties WebDAV has no slot for: dead properties where the
# server really stores them (Probe), otherwise only the mirror.
sub _filenode_dead_set {
  my ($Self, $href, $props) = @_;
  return unless %$props && $Self->filenode_features()->{deadProps};
  $Self->backend_cmd('files_prop_patch', $href, $props);
}

sub _filenode_children {
  my ($Self, $nodeid) = @_;
  return $Self->dget('jfilenodes', { parentid => $nodeid, active => 1 });
}

sub _filenode_subtree {
  my ($Self, $nodeid) = @_;
  my @all;
  my @todo = ($nodeid);
  while (defined(my $id = shift @todo)) {
    for my $c (@{ $Self->_filenode_children($id) }) { push @all, $c; push @todo, $c->{nodeid} }
  }
  return \@all;
}

sub destroy_filenodes {
  my ($Self, $ids, $opts) = @_;
  my (@destroyed, %notdestroyed);
  my %destroying = map { $_ => 1 } @$ids;
  # children before parents: the deepest first
  $Self->begin();
  my %row = map { $_ => $Self->filenode_row($_) } @$ids;
  $Self->commit();
  my $depth = sub { my $h = $_[0] ? $_[0]{href} : ''; scalar(() = $h =~ m{/}g) };
  for my $id (sort { $depth->($row{$b}) <=> $depth->($row{$a}) } @$ids) {
    my $r = $row{$id} or do { $notdestroyed{$id} = { type => 'notFound' }; next };
    if ($r->{role} && $r->{role} eq 'home') { $notdestroyed{$id} = { type => 'forbidden' }; next }
    $Self->begin();
    my $sub = $Self->_filenode_subtree($id);
    $Self->commit();
    if (grep { !$destroying{$_->{nodeid}} } @$sub and !$opts->{onDestroyRemoveChildren}) {
      $notdestroyed{$id} = { type => 'nodeHasChildren' };
      next;
    }
    my $status = $Self->backend_cmd('files_delete', $r->{nodetype} eq 'directory' ? "$r->{href}/" : $r->{href});
    unless ($status =~ /^2/ || $status == 404) {
      $notdestroyed{$id} = { type => 'serverFail', description => "DELETE: HTTP $status" };
      next;
    }
    $Self->begin();
    for my $gone ($r, @$sub) {
      next unless $Self->filenode_row($gone->{nodeid});
      $Self->ddirty('jfilenodes', { active => 0 }, { nodeid => $gone->{nodeid} });
      push @destroyed, $gone->{nodeid};
    }
    $Self->commit();
  }
  return (\@destroyed, \%notdestroyed);
}

sub create_filenodes {
  my ($Self, $create, $idmap, $opts) = @_;
  my (%created, %notcreated, @alsodestroyed);
  my %known = map { $_ => 1 } qw(parentId nodeType blobId target size name type created modified accessed executable isSubscribed role);
  for my $cid (@{ JMAP::FileNode::order_creates($create) }) {
    my $c = $create->{$cid};
    my @bad = grep { !$known{$_} } keys %$c;
    push @bad, 'role' if defined $c->{role};
    my $nodetype = $c->{nodeType} // (defined $c->{target} ? 'symlink' : defined $c->{blobId} ? 'file' : 'directory');
    push @bad, 'nodeType' unless $nodetype =~ /^(?:file|directory)$/;  # no symlinks over WebDAV
    push @bad, 'blobId' if $nodetype eq 'file' && !defined $c->{blobId};
    push @bad, 'blobId' if $nodetype eq 'directory' && defined $c->{blobId};
    push @bad, 'name' if JMAP::FileNode::name_problem($c->{name});
    push @bad, 'type' if defined $c->{type} && ($nodetype ne 'file' || $c->{type} !~ m{^[\w!#\$&^.+-]+/[\w!#\$&^.+-]+(?:\s*;.*)?$});
    my $pid = $idmap->($c->{parentId} // '');
    $Self->begin();
    my $parent = $pid && $Self->filenode_row($pid);
    $Self->commit();
    push @bad, 'parentId' unless $parent && $parent->{nodetype} eq 'directory';
    if (@bad) { $notcreated{$cid} = { type => 'invalidProperties', properties => [ sort { $a cmp $b } keys %{{ map { $_ => 1 } @bad }} ] }; next }

    my ($content, $ctype);
    if ($nodetype eq 'file') {
      ($ctype, $content) = $Self->get_blob($c->{blobId});
      unless (defined $content) { $notcreated{$cid} = { type => 'invalidProperties', properties => ['blobId'] }; next }
      if (defined $c->{size} && $c->{size} != length $content) {
        $notcreated{$cid} = { type => 'invalidProperties', properties => ['size'] }; next;
      }
    }

    # name clash (draft S3.2.3 onExists)
    my $name = $c->{name};
    $Self->begin();
    my $siblings = $Self->_filenode_children($pid);
    $Self->commit();
    my $key = $opts->{ci} ? sub { lc $_[0] } : sub { $_[0] };
    my ($clash) = grep { $key->($_->{name}) eq $key->($name) } @$siblings;
    if ($clash) {
      my $mode = $opts->{onExists} // '';
      my $newer = ($mode eq 'newest') && (JMAP::FileNode::epoch($c->{modified}) // time()) > ($clash->{modified} // 0);
      if ($mode eq 'rename') {
        $name = JMAP::FileNode::unique_name($name, { map { ($key->($_->{name}) => 1) } @$siblings });
      }
      elsif ($mode eq 'replace' || $newer) {
        my ($gone, $not) = $Self->destroy_filenodes([ $clash->{nodeid} ], $opts);
        if ($not->{ $clash->{nodeid} }) { $notcreated{$cid} = $not->{ $clash->{nodeid} }; next }
        push @alsodestroyed, @$gone;
      }
      else {
        $notcreated{$cid} = { type => 'alreadyExists', existingId => "$clash->{nodeid}" };
        next;
      }
    }

    my $href = "$parent->{href}/$name";
    my $status = $nodetype eq 'directory'
      ? $Self->backend_cmd('files_mkcol', $href)
      : $Self->backend_cmd('files_put', $href, $content, type => ($c->{type} // $ctype), if_none_match => 1)->{status};
    unless ($status =~ /^2/) {
      $notcreated{$cid} = { type => ($status == 412 || $status == 405 ? 'alreadyExists' : 'serverFail'),
                            description => "WebDAV: HTTP $status" };
      next;
    }
    my %dead = map { ($_ => $c->{$_}) } grep { defined $c->{$_} } qw(created modified accessed);
    $dead{executable} = $c->{executable} ? 1 : 0 if exists $c->{executable};
    $dead{isSubscribed} = $c->{isSubscribed} ? 1 : 0 if exists $c->{isSubscribed};
    $Self->_filenode_dead_set($href, \%dead);
    my $rows = $Self->_files_refresh_dir($parent->{href});
    my $row = $rows->{$href} or do { $notcreated{$cid} = { type => 'serverFail', description => 'created node not listed' }; next };
    # what the server could not store lives in the mirror
    my %mirror;
    $mirror{created}  = JMAP::FileNode::epoch($c->{created})  if defined $c->{created};
    $mirror{modified} = JMAP::FileNode::epoch($c->{modified}) if defined $c->{modified};
    $mirror{accessed} = JMAP::FileNode::epoch($c->{accessed}) if defined $c->{accessed};
    $mirror{executable}   = $c->{executable} ? 1 : 0 if exists $c->{executable};
    $mirror{isSubscribed} = $c->{isSubscribed} ? 1 : 0 if exists $c->{isSubscribed};
    if (%mirror) { $Self->begin(); $Self->ddirty('jfilenodes', \%mirror, { nodeid => $row->{nodeid} }); $Self->commit(); }
    $created{$cid} = { %$row, %mirror };
  }
  return (\%created, \%notcreated, \@alsodestroyed);
}
```

- [ ] **Step 7: `api_FileNode_set` (create + destroy now; update in Task 8)**

Append to `JMAP/API/FileNode.pm`:

```perl
sub api_FileNode_set {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my $oldState = "$user->{jstateFileNode}";
  $Self->commit();
  return ['error', { type => 'stateMismatch' }] if defined $args->{ifInState} && $args->{ifInState} ne $oldState;
  my $onExists = $args->{onExists};
  return ['error', { type => 'invalidArguments', arguments => ['onExists'] }]
    if defined $onExists && $onExists !~ /^(?:replace|rename|newest)$/;   # "unchanged" needs JMAP-CONDITIONAL
  my %opts = (onExists => $onExists, onDestroyRemoveChildren => $args->{onDestroyRemoveChildren} ? 1 : 0,
              ci => $args->{compareCaseInsensitively} ? 1 : 0);

  my $scoped_lock = $Self->{db}->begin_superlock();
  # destroys first, so a create may reuse a freed name (draft S3.2.3)
  my ($destroyed, $notDestroyed) = $Self->{db}->destroy_filenodes([ map { $Self->idmap($_) } @{ $args->{destroy} || [] } ], \%opts);
  my ($created, $notCreated, $also) = $Self->{db}->create_filenodes($args->{create} || {}, sub { $Self->idmap(shift) }, \%opts);
  $Self->setid($_, $created->{$_}{nodeid}) for keys %$created;
  my ($updated, $notUpdated, $also2) = ({}, {}, []);
  if (%{ $args->{update} || {} }) {
    if ($Self->{db}->can('update_filenodes')) {   # Task 8
      ($updated, $notUpdated, $also2) = $Self->{db}->update_filenodes($args->{update}, sub { $Self->idmap(shift) }, \%opts);
    }
    else {
      $notUpdated = { map { $_ => { type => 'serverFail', description => 'update not implemented yet' } } keys %{$args->{update}} };
    }
  }

  $Self->begin();
  my $rows = $Self->{db}->filenode_rows();
  my %byid = map { $_->{nodeid} => $_ } @$rows;
  $user = $Self->{db}->get_user();
  my $newState = "$user->{jstateFileNode}";
  $Self->commit();

  # created: id plus every server-set or defaulted property (RFC 8620 S5.3)
  my %createdOut;
  for my $cid (keys %$created) {
    my $full = $Self->_filenode_object($created->{$cid}, \%byid);
    my $sent = $args->{create}{$cid};
    $createdOut{$cid} = { map { ($_ => $full->{$_}) } grep { $_ eq 'id' || !exists $sent->{$_} || ($_ eq 'name' && $full->{name} ne $sent->{name}) } keys %$full };
  }
  return ['FileNode/set', {
    accountId => $accountid, oldState => $oldState, newState => $newState,
    created => _nullempty(\%createdOut), notCreated => _nullempty($notCreated),
    updated => _nullempty($updated), notUpdated => _nullempty($notUpdated),
    destroyed => _nullempty([ map { "$_" } @$destroyed, @$also, @$also2 ]), notDestroyed => _nullempty($notDestroyed),
  }];
}
```

Add `FileNode/set` to `JMAP::Dispatch` if it was held back in Task 5.

- [ ] **Step 8: Run all tests** — `prove -l t/` then the integration test against a clean stack. Expected PASS.

- [ ] **Step 9: Commit**

```bash
git add JMAP/ImapDB.pm JMAP/API/FileNode.pm JMAP/Dispatch.pm t/filenode-webdav.t
git commit -m "files: FileNode/set create and destroy over WebDAV, with onExists"
```

---

### Task 7: Downloads (`d-` blobs) and direct HTTP PUT

**Files:**
- Modify: `JMAP/DB.pm` (`get_blob`)
- Modify: `JMAP/ImapDB.pm` (`get_filenode_blob`, `put_filenode_content`)
- Modify: `bin/jmap-proxy.pl` (worker command `filenode_put`; route `PUT /filenode/{accountId}/{id}`)
- Test: `t/filenode-webdav.t` (extend)

**Interfaces:**
- Produces:
  - `ImapDB::get_filenode_blob($blobId) -> ($type, $bytes)` or `()` (wrong/old etag → `()`).
  - `ImapDB::put_filenode_content($nodeid, $bytes, $type) -> { status => 200|400|403|404|409|412, blobId, size, type }`.
  - Worker command `filenode_put` with args `{ id, file, type }` (`file` is a temp path, like `upload`) → that hashref.
  - `get_blob('d-…')` works everywhere blobs are fetched (download, `fetch_blobs`, `Blob/get`, FileNode create from another node's blob).

- [ ] **Step 1: Extend the integration test (failing)**

```perl
# --- downloads and direct writes (Task 7)
my ($mkf) = @{ jmap(['FileNode/set', { create => { f => { parentId => $home->{id}, name => "$tag-dl.txt", blobId => $blob->{blobId} } } }]) };
my $fid = $mkf->{created}{f}{id};
my ($fg) = @{ jmap(['FileNode/get', { ids => [ $fid ] }]) };
my $fb = $fg->{list}[0]{blobId};
my $dl = $http->get("$ENV{JMAP_PROXY_URL}/raw/$user/$fb/x.txt?type=text/plain", { headers => { Authorization => $auth } });
is($dl->{content}, 'uploaded', 'download a FileNode blob');

my $put = $http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid",
  { headers => { Authorization => $auth, 'Content-Type' => 'text/markdown; charset=utf-8' }, content => '# new' });
is($put->{status}, 200, 'direct PUT');
my $pj = decode_json($put->{content});
is($pj->{size}, 5, 'size');
is($pj->{type}, 'text/markdown', 'type without parameters');
isnt($pj->{blobId}, $fb, 'new blobId');
is($http->get("$ENV{JMAP_PROXY_URL}/raw/$user/$fb/x.txt?type=text/plain", { headers => { Authorization => $auth } })->{status}, 404,
   'the old blob no longer exists');
is($http->request('PUT', "$ENV{JMAP_PROXY_URL}/filenode/$user/$home->{id}", { headers => { Authorization => $auth }, content => 'x' })->{status}, 400,
   'PUT to a directory is 400');
is($http->request('PATCH', "$ENV{JMAP_PROXY_URL}/filenode/$user/$fid", { headers => { Authorization => $auth }, content => 'x' })->{status}, 415,
   'PATCH is 415');
jmap(['FileNode/set', { destroy => [ $fid ] }]);
```

Run — expected FAIL (download returns 404/empty; PUT route missing).

- [ ] **Step 2: `get_blob` learns `d-`** — in `JMAP/DB.pm`'s `get_blob`, before the `m/^([mf])-…/` check:

```perl
  if ($blobId =~ /^d-/) {
    return $Self->can('get_filenode_blob') ? $Self->get_filenode_blob($blobId) : ();
  }
```

- [ ] **Step 3: `get_filenode_blob` and `put_filenode_content` in `JMAP/ImapDB.pm`**

```perl
sub get_filenode_blob {
  my ($Self, $blobId) = @_;
  my ($nodeid, $etaghash) = JMAP::FileNode::parse_blob_id($blobId) or return ();
  $Self->begin();
  my $row = $Self->filenode_row($nodeid);
  $Self->commit();
  return () unless $row && $row->{nodetype} eq 'file'
                && JMAP::FileNode::blob_id($nodeid, $row->{etag}) eq $blobId;
  my $res = $Self->backend_cmd('files_get', $row->{href}, if_match => $row->{etag});
  return () unless $res->{status} == 200;   # 412: changed since -- that blob is gone
  return ($row->{type} || $res->{type} || 'application/octet-stream', $res->{content});
}

# draft S4.1: PUT replaces a file's content.
sub put_filenode_content {
  my ($Self, $nodeid, $bytes, $type) = @_;
  $Self->begin();
  my $row = $Self->filenode_row($nodeid);
  my $parent = $row && defined $row->{parentid} ? $Self->filenode_row($row->{parentid}) : undef;
  $Self->commit();
  return { status => 404 } unless $row;
  return { status => 400 } unless $row->{nodetype} eq 'file';
  my $r = JMAP::FileNode::rights(defined $row->{privs} ? [split ' ', $row->{privs}] : undef,
                                 $parent && defined $parent->{privs} ? [split ' ', $parent->{privs}] : undef);
  return { status => 403 } unless $r->{mayModifyContent};
  ($type //= $row->{type}) =~ s/\s*;.*$//;
  my $res = $Self->backend_cmd('files_put', $row->{href}, $bytes, type => $type, if_match => $row->{etag});
  return { status => ($res->{status} == 412 ? 412 : 409) } unless $res->{status} =~ /^2/;
  my $rows = $Self->_files_refresh_dir($parent->{href});
  my $new = $rows->{$row->{href}} or return { status => 409 };
  $Self->begin();
  $Self->ddirty('jfilenodes', { type => $type }, { nodeid => $nodeid }) if ($new->{type} // '') ne $type;
  $Self->commit();
  return { status => 200, blobId => JMAP::FileNode::blob_id($nodeid, $new->{etag}), size => 0 + length($bytes), type => $type };
}
```

- [ ] **Step 4: Worker command and HTTP route in `bin/jmap-proxy.pl`**

Worker, next to `upload`:

```perl
      if ($cmd eq 'filenode_put') {
        return ['filenode_put', { status => 404 }] unless $db->can('put_filenode_content');
        my $bytes = do { local $/; open my $fh, '<:raw', $args->{file} or die "$args->{file}: $!"; <$fh> };
        unlink $args->{file};
        return ['filenode_put', $db->put_filenode_content($args->{id}, $bytes, $args->{type})];
      }
```

Parent: copy the structure of the `/upload` handler (it already authenticates, checks account access and spools the body to a temp file for the worker). Register `'/filenode' => \&do_filenode_write` in the route table, with:

```perl
# draft-ietf-jmap-filenode S4: direct HTTP write of a file's content.
sub do_filenode_write {
  my ($httpd, $req) = @_;
  my ($accountid, $id) = $req->url->path =~ m{^/filenode/([^/]+)/([^/]+)$} or return not_found($req);
  return $req->respond([415, 'unsupported', {}, 'PATCH is not supported']) if $req->method eq 'PATCH';
  return $req->respond([405, 'method not allowed', { Allow => 'PUT' }, '']) unless $req->method eq 'PUT';
  $httpd->stop_request();
  _authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    _check_account_access($auth_aid, $accountid, sub {
      my $file = _spool_body_to_temp($req);   # the helper /upload uses
      send_backend_request($accountid, 'filenode_put',
        { id => $id, file => $file, type => $req->headers->{'content-type'} }, sub {
          my $r = shift;
          return $req->respond([$r->{status}, 'error', {}, '']) unless $r->{status} == 200;
          $req->respond([200, 'ok', { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json({ blobId => $r->{blobId}, size => $r->{size}, type => $r->{type} })]);
        }, sub { $req->respond([500, 'error', {}, '']) });
    }, sub { $req->respond([403, 'forbidden', {}, 'Forbidden']) });
  }, sub { _require_auth($req) });
}
```

(Use whatever the existing `/upload` handler calls to write the body to a temp file — read `do_upload` and reuse its helper rather than writing a new one; if it inlines the logic, factor it into `_spool_body_to_temp` as part of this step.)

- [ ] **Step 5: Run tests** — unit + integration; expected PASS.

- [ ] **Step 6: Commit**

```bash
git add JMAP/DB.pm JMAP/ImapDB.pm bin/jmap-proxy.pl t/filenode-webdav.t
git commit -m "files: download FileNode blobs and write content with HTTP PUT"
```

---

### Task 8: FileNode/set update — rename, move, content, properties

**Files:**
- Modify: `JMAP/FileNode.pm` (`order_moves`)
- Modify: `JMAP/ImapDB.pm` (`update_filenodes`)
- Test: `t/filenode-order.t` (extend), `t/filenode-webdav.t` (extend)

**Interfaces:**
- Produces:
  - `JMAP::FileNode::order_moves(\%moves, \%occupant) -> [ [id, $temp_or_undef]... ]` where `%moves` is `id => "newparent\0newname"`, `%occupant` is `"parent\0name" => id` for the current tree; moves whose destination is occupied by another mover come after that mover; a cycle is broken by first moving one node to a temporary name (`.~tmp~<id>`), returned as `[id, '.~tmp~<id>']` early and `[id, undef]` at the end.
  - `ImapDB::update_filenodes(\%update, $idmap, \%opts) -> (\%updated, \%notUpdated, \@alsoDestroyed)`.

- [ ] **Step 1: Unit test for move ordering (append to `t/filenode-order.t`)**

```perl
my $om = \&JMAP::FileNode::order_moves;
# swap a and b
my $steps = $om->({ A => "p\0b", B => "p\0a" }, { "p\0a" => 'A', "p\0b" => 'B' });
is(scalar @$steps, 3, 'a swap takes three steps');
ok(defined $steps->[0][1] && $steps->[0][1] =~ /^\.~tmp~/, 'the first step parks one node under a temporary name');
my $parked = $steps->[0][0];
my ($other) = grep { $_ ne $parked } qw(A B);
is_deeply([ map { [ $_->[0], $_->[1] ] } @$steps[1, 2] ], [ [ $other, undef ], [ $parked, undef ] ],
  'then the other node moves, then the parked one moves to its real destination');
# a chain: c -> where b is, b -> where a is
$steps = $om->({ B => "p\0a", C => "p\0b" }, { "p\0a" => 'A', "p\0b" => 'B', "p\0c" => 'C' });
is_deeply([ map { $_->[0] } @$steps ], [ 'B', 'C' ], 'B vacates b before C takes it');
# (A is not moving, so B's own clash with A is not order_moves' business: update_filenodes
# resolves clashes with non-moving nodes through onExists before ordering.)
```

Run — FAIL. Then implement in `JMAP/FileNode.pm`:

```perl
# draft S3.2.3: sibling names must stay unique at every step.  A move whose
# destination is held by another mover waits for it; a cycle is broken by
# parking one node under a temporary name (as hm's _get_ordered_update_keys).
sub order_moves {
  my ($moves, $occupant) = @_;
  my %pending = %$moves;
  my %held = %$occupant;
  my @steps;
  while (%pending) {
    my $progress = 0;
    for my $id (sort keys %pending) {
      my $dest = $pending{$id};
      my $holder = $held{$dest};
      next if defined $holder && $holder ne $id && exists $pending{$holder};
      push @steps, [$id, undef];
      delete $held{$_} for grep { ($held{$_} // '') eq $id } keys %held;
      $held{$dest} = $id;
      delete $pending{$id};
      $progress = 1;
    }
    next if $progress;
    my ($id) = sort keys %pending;     # a cycle: park one
    push @steps, [$id, ".~tmp~$id"];
    delete $held{$_} for grep { ($held{$_} // '') eq $id } keys %held;
    my $park = $pending{$id};
    delete $pending{$id};
    my @rest = order_moves({ map { $_ => $pending{$_} } keys %pending }, \%held);
    push @steps, @{ $rest[0] }, [$id, undef];
    %pending = ();
  }
  return \@steps;
}
```

Run `prove -l t/filenode-order.t` — PASS (fix the test expectation, not the code, only if the test's arithmetic is wrong; the rule is "unique names at every step").

- [ ] **Step 2: Integration cases (append to `t/filenode-webdav.t`, failing)**

```perl
# --- update (Task 8)
my ($u0) = @{ jmap(['FileNode/set', { create => {
  P => { parentId => $home->{id}, name => "$tag-P" },
  Q => { parentId => '#P', name => 'Q' },
  a => { parentId => '#P', name => 'a.txt', blobId => $blob->{blobId} },
  b => { parentId => '#P', name => 'b.txt', blobId => $blob->{blobId} },
} }]) };
my %id = map { $_ => $u0->{created}{$_}{id} } qw(P Q a b);

my ($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { name => 'b.txt' }, $id{b} => { name => 'a.txt' } } }]) };
ok(exists $u->{updated}{$id{a}} && exists $u->{updated}{$id{b}}, 'swap two names in one /set') or diag explain $u;
my ($ga) = @{ jmap(['FileNode/get', { ids => [ $id{a} ], properties => ['name'] }]) };
is($ga->{list}[0]{name}, 'b.txt', 'a is now b.txt, same id');

($u) = @{ jmap(['FileNode/set', { update => { $id{P} => { parentId => $id{Q} } } }]) };
is($u->{notUpdated}{$id{P}}{type}, 'invalidProperties', 'moving a directory into its own child');
is_deeply($u->{notUpdated}{$id{P}}{properties}, ['parentId'], 'on parentId');

($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { parentId => $id{Q}, name => "x y %#.txt" } } }]) };
ok(exists $u->{updated}{$id{a}}, 'move and rename together');
ok((grep { $_->{href} eq "$root/$tag-P/Q/x y %#.txt" } @{ $dav->PropFind("$root/$tag-P/Q", 1) }), 'moved on the server');

($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { executable => JSON::true, accessed => '2026-01-02T03:04:05Z' } } }]) };
my ($gx) = @{ jmap(['FileNode/get', { ids => [ $id{a} ], properties => ['executable', 'accessed'] }]) };
ok($gx->{list}[0]{executable}, 'executable round-trips even where dead props are not stored');
is($gx->{list}[0]{accessed}, '2026-01-02T03:04:05Z', 'accessed round-trips');

($u) = @{ jmap(['FileNode/set', { update => { $id{a} => { nodeType => 'directory' } } }]) };
is($u->{notUpdated}{$id{a}}{type}, 'invalidProperties', 'nodeType is immutable');

my $blob2 = decode_json($http->post("$ENV{JMAP_PROXY_URL}/upload/$user/", { headers => { Authorization => $auth, 'Content-Type' => 'text/plain' }, content => 'second!' })->{content});
($u) = @{ jmap(['FileNode/set', { update => { $id{b} => { blobId => $blob2->{blobId} } } }]) };
is($u->{updated}{$id{b}}{size}, 7, 'content replaced; size reported');

jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $id{P} ] }]);
```

Run — FAIL.

- [ ] **Step 3: Implement `update_filenodes` in `JMAP/ImapDB.pm`**

```perl
sub update_filenodes {
  my ($Self, $update, $idmap, $opts) = @_;
  my (%updated, %notupdated, @alsodestroyed);
  my %settable = map { $_ => 1 } qw(parentId name blobId type size created modified accessed executable isSubscribed shareWith);
  $Self->begin();
  my %byid = map { $_->{nodeid} => $_ } @{ $Self->filenode_rows() };
  $Self->commit();
  my $key = $opts->{ci} ? sub { lc $_[0] } : sub { $_[0] };

  my (%moves, %plan);
  for my $uid (sort keys %$update) {
    my $id = $idmap->($uid);
    my $row = $byid{$id} or do { $notupdated{$uid} = { type => 'notFound' }; next };
    my $p = $update->{$uid};
    my @bad = grep { !$settable{$_} } keys %$p;
    push @bad, 'name'   if exists $p->{name} && JMAP::FileNode::name_problem($p->{name});
    push @bad, 'blobId' if exists $p->{blobId} && ($row->{nodetype} ne 'file' || !defined $p->{blobId});
    push @bad, 'type'   if exists $p->{type} && $row->{nodetype} ne 'file';
    if (exists $p->{parentId} || exists $p->{name}) {
      my $newparent = exists $p->{parentId} ? $idmap->($p->{parentId} // '') : $row->{parentid};
      push @bad, 'parentId' if ($row->{role} // '') eq 'home';
      push @bad, 'parentId' unless $newparent && $byid{$newparent} && $byid{$newparent}{nodetype} eq 'directory';
      # draft S3.2.3: no cycles
      for (my $a = $newparent; defined $a; $a = $byid{$a} ? $byid{$a}{parentid} : undef) {
        if ($a eq $id) { push @bad, 'parentId'; last }
      }
      $moves{$id} = ($newparent // '') . "\0" . ($p->{name} // $row->{name}) unless @bad;
    }
    if (@bad) { $notupdated{$uid} = { type => 'invalidProperties', properties => [ sort keys %{{ map { $_ => 1 } @bad }} ] }; next }
    $plan{$id} = [$uid, $p];
  }

  # name clashes against nodes that are not moving
  my %occupant = map { (($_->{parentid} // '') . "\0" . $key->($_->{name})) => $_->{nodeid} } values %byid;
  for my $id (keys %moves) {
    my ($np, $nn) = split /\0/, $moves{$id}, 2;
    my $holder = $occupant{"$np\0" . $key->($nn)};
    next unless defined $holder && $holder ne $id && !exists $moves{$holder};
    my $mode = $opts->{onExists} // '';
    if ($mode eq 'rename') {
      my %taken = map { ($key->($_->{name}) => 1) } grep { ($_->{parentid} // '') eq $np } values %byid;
      $moves{$id} = "$np\0" . JMAP::FileNode::unique_name($nn, \%taken);
    }
    elsif ($mode eq 'replace' || ($mode eq 'newest' && (JMAP::FileNode::epoch($plan{$id}[1]{modified}) // $byid{$id}{modified} // 0) > ($byid{$holder}{modified} // 0))) {
      my ($gone, $not) = $Self->destroy_filenodes([ $holder ], $opts);
      if ($not->{$holder}) { $notupdated{$plan{$id}[0]} = $not->{$holder}; delete $moves{$id}; delete $plan{$id}; next }
      push @alsodestroyed, @$gone;
    }
    else {
      $notupdated{$plan{$id}[0]} = { type => 'alreadyExists', existingId => "$holder" };
      delete $moves{$id}; delete $plan{$id};
    }
  }

  my %occ = map { (($_->{parentid} // '') . "\0" . $_->{name}) => $_->{nodeid} } values %byid;
  my %href = map { $_ => $byid{$_}{href} } keys %byid;
  my %touched;
  for my $step (@{ JMAP::FileNode::order_moves(\%moves, \%occ) }) {
    my ($id, $temp) = @$step;
    next unless $plan{$id};
    my ($np, $nn) = split /\0/, $moves{$id}, 2;
    my $dest = defined $temp ? "$href{$byid{$id}{parentid}}/$temp" : "$href{$np}/$nn";
    my $isdir = $byid{$id}{nodetype} eq 'directory';
    my $status = $Self->backend_cmd('files_move', $isdir ? "$href{$id}/" : $href{$id}, $isdir ? "$dest/" : $dest, overwrite => 0);
    unless ($status =~ /^2/) {
      $notupdated{$plan{$id}[0]} = { type => 'serverFail', description => "MOVE: HTTP $status" };
      delete $plan{$id};
      next;
    }
    $touched{$_} = 1 for $href{$id} =~ s{/[^/]+$}{}r, $dest =~ s{/[^/]+$}{}r;
    # descendants' hrefs move with a directory
    my $old = $href{$id};
    $href{$_} =~ s{^\Q$old\E(?=/|$)}{$dest} for keys %href;
    $Self->begin();
    $Self->dmaybeupdate('jfilenodes', { href => $dest, name => ($dest =~ m{([^/]+)$})[0], parentid => $np, changed => time() }, { nodeid => $id })
      unless defined $temp;
    for my $d (@{ $Self->_filenode_subtree($id) }) {
      $Self->dmaybeupdate('jfilenodes', { href => $href{$d->{nodeid}} }, { nodeid => $d->{nodeid} });
    }
    $Self->ddirty('jfilenodes', { changed => time() }, { nodeid => $id });
    $Self->commit();
  }

  # content and properties
  for my $id (keys %plan) {
    my ($uid, $p) = @{$plan{$id}};
    my %out;
    if (exists $p->{blobId}) {
      my ($ctype, $bytes) = $Self->get_blob($p->{blobId});
      unless (defined $bytes) { $notupdated{$uid} = { type => 'invalidProperties', properties => ['blobId'] }; next }
      if (defined $p->{size} && $p->{size} != length $bytes) { $notupdated{$uid} = { type => 'invalidProperties', properties => ['size'] }; next }
      my $r = $Self->put_filenode_content($id, $bytes, $p->{type} // $ctype);
      unless ($r->{status} == 200) { $notupdated{$uid} = { type => ($r->{status} == 403 ? 'forbidden' : 'serverFail'), description => "PUT: HTTP $r->{status}" }; next }
      @out{qw(blobId size type)} = @$r{qw(blobId size type)};
    }
    my %mirror;
    $mirror{$_} = (defined $p->{$_} ? JMAP::FileNode::epoch($p->{$_}) : time()) for grep { exists $p->{$_} } qw(modified accessed);
    $mirror{created} = JMAP::FileNode::epoch($p->{created}) if defined $p->{created};
    $mirror{executable}   = $p->{executable} ? 1 : 0 if exists $p->{executable};
    $mirror{isSubscribed} = $p->{isSubscribed} ? 1 : 0 if exists $p->{isSubscribed};
    $mirror{type} = $p->{type} if exists $p->{type} && !exists $p->{blobId};
    if (%mirror) {
      $Self->_filenode_dead_set($href{$id}, { map { ($_ => ($_ =~ /^(?:created|modified|accessed)$/ ? JMAP::FileNode::utc($mirror{$_}) : $mirror{$_})) } grep { $_ ne 'type' } keys %mirror });
      $Self->begin();
      $Self->ddirty('jfilenodes', { %mirror, changed => time() }, { nodeid => $id });
      $Self->commit();
      $out{modified} = JMAP::FileNode::utc($mirror{modified}) if exists $p->{modified} && !defined $p->{modified};
      $out{accessed} = JMAP::FileNode::utc($mirror{accessed}) if exists $p->{accessed} && !defined $p->{accessed};
    }
    if (exists $p->{name} && $moves{$id} && (split /\0/, $moves{$id}, 2)[1] ne $p->{name}) {
      $out{name} = (split /\0/, $moves{$id}, 2)[1];
    }
    $updated{$id} = %out ? \%out : undef;
  }
  $Self->_files_refresh_dir($_) for sort keys %touched;
  return (\%updated, \%notupdated, \@alsodestroyed);
}
```

(`shareWith` is accepted here and handled in Task 10; until then, if present, report `invalidProperties` on `shareWith`.)

- [ ] **Step 4: Run tests** — unit and integration; expected PASS.

- [ ] **Step 5: Commit**

```bash
git add JMAP/FileNode.pm JMAP/ImapDB.pm t/filenode-order.t t/filenode-webdav.t
git commit -m "files: FileNode/set update -- moves (swaps, cycles), content, properties"
```

---

### Task 9: FileNode/query and FileNode/queryChanges

**Files:**
- Modify: `JMAP/FileNode.pm` (`filter_match`, `sort_nodes`)
- Modify: `JMAP/API/FileNode.pm` (`api_FileNode_query`, `api_FileNode_queryChanges`)
- Modify: `JMAP/API.pm` (`%FILTER_CONDITIONS` gains FileNode keys)
- Test: `t/filenode-query.t` (unit), `t/filenode-webdav.t` (extend)

**Interfaces:**
- Produces:
  - `JMAP::FileNode::filter_match($obj, $filter, $ctx) -> 0|1` where `$obj` is a FileNode object (Task 5 `_filenode_object`) and `$ctx = { byid => {id => obj}, ancestors => {id => {ancestorId => 1}} }`. Handles AND/OR/NOT and every draft filter except `body` (rejected earlier as `unsupportedFilter`).
  - `JMAP::FileNode::sort_nodes(\@objs, \@sort, $byid) -> \@sorted` — supports `name type size created modified accessed nodeType tree`, honours `isAscending` and `collation`; ties broken by `id`.

- [ ] **Step 1: Unit test**

```perl
#!/usr/bin/perl
# t/filenode-query.t
use strict;
use warnings;
use Test::More;
use JSON;
use lib '.';
use JMAP::FileNode;

my @o = (
  { id => 'R', parentId => undef, nodeType => 'directory', name => 'home', role => 'home', size => undef, type => undef, created => '2026-01-01T00:00:00Z', modified => '2026-01-01T00:00:00Z', accessed => '2026-01-01T00:00:00Z', executable => JSON::false, blobId => undef },
  { id => 'D', parentId => 'R', nodeType => 'directory', name => 'Docs', role => undef, size => undef, type => undef, created => '2026-02-01T00:00:00Z', modified => '2026-02-01T00:00:00Z', accessed => '2026-02-01T00:00:00Z', executable => JSON::false, blobId => undef },
  { id => 'a', parentId => 'D', nodeType => 'file', name => 'apple.TXT', role => undef, size => 10, type => 'text/plain', created => '2026-03-01T00:00:00Z', modified => '2026-03-02T00:00:00Z', accessed => '2026-03-03T00:00:00Z', executable => JSON::true, blobId => 'd-a-1' },
  { id => 'b', parentId => 'R', nodeType => 'file', name => 'Banana.png', role => undef, size => 200, type => 'image/png', created => '2026-04-01T00:00:00Z', modified => '2026-04-01T00:00:00Z', accessed => '2026-04-01T00:00:00Z', executable => JSON::false, blobId => 'd-b-1' },
);
my %byid = map { $_->{id} => $_ } @o;
my $ctx = { byid => \%byid };
my $q = sub { my $f = shift; [ map { $_->{id} } grep { JMAP::FileNode::filter_match($_, $f, $ctx) } @o ] };

is_deeply($q->({ isTopLevel => JSON::true }), ['R'], 'isTopLevel');
is_deeply($q->({ parentId => 'D' }), ['a'], 'parentId');
is_deeply($q->({ ancestorId => 'R' }), [qw(D a b)], 'ancestorId');
is_deeply($q->({ descendantId => 'a' }), [qw(R D)], 'descendantId');
is_deeply($q->({ nodeType => 'file' }), [qw(a b)], 'nodeType');
is_deeply($q->({ hasAnyRole => JSON::true }), ['R'], 'hasAnyRole');
is_deeply($q->({ isExecutable => JSON::true }), ['a'], 'isExecutable');
is_deeply($q->({ minSize => 10, maxSize => 200 }), ['a'], 'minSize inclusive, maxSize exclusive');
is_deeply($q->({ createdBefore => '2026-03-01T00:00:00Z' }), [qw(R D)], 'Before is exclusive');
is_deeply($q->({ createdAfter => '2026-03-01T00:00:00Z' }), [qw(a b)], 'After is inclusive');
is_deeply($q->({ name => 'apple.TXT' }), ['a'], 'name: exact octets');
is_deeply($q->({ name => 'apple.txt' }), [], 'name is case-sensitive');
is_deeply($q->({ nameMatch => '*.txt' }), ['a'], 'nameMatch is case-insensitive');
is_deeply($q->({ typeMatch => 'image/*' }), ['b'], 'typeMatch');
is_deeply($q->({ text => 'banana' }), ['b'], 'text = nameMatch or typeMatch (substring)');
is_deeply($q->({ blobId => 'd-a-1' }), ['a'], 'blobId');
is_deeply($q->({ operator => 'NOT', conditions => [ { nodeType => 'directory' } ] }), [qw(a b)], 'NOT');

my $s = sub { [ map { $_->{id} } @{ JMAP::FileNode::sort_nodes([@o], shift, \%byid) } ] };
is_deeply($s->([ { property => 'name' } ]), [qw(a b D R)], 'name sort is case-insensitive by default');
is_deeply($s->([ { property => 'name', collation => 'i;octet' } ]), [qw(b D a R)], 'i;octet: raw byte order, "Banana.png" "Docs" "apple.TXT" "home"');
is_deeply($s->([ { property => 'nodeType' } ]), [qw(D R a b)], 'directories first');
is_deeply($s->([ { property => 'size', isAscending => JSON::false } ]), [qw(b a D R)], 'size descending, null last then id');
is_deeply($s->([ { property => 'tree' } ]), [qw(R D a b)], 'tree: depth-first, directories first, then by name');

done_testing;
```


Run — FAIL.

- [ ] **Step 2: Implement (append to `JMAP/FileNode.pm`)**

```perl
use JMAP::Collation;

sub _ancestors {
  my ($id, $byid) = @_;
  my @a;
  my %seen;
  for (my $p = $byid->{$id} ? $byid->{$id}{parentId} : undef; defined $p && !$seen{$p}++; $p = $byid->{$p} ? $byid->{$p}{parentId} : undef) {
    push @a, $p;
  }
  return @a;
}

# draft S3.2.5 FilterCondition / RFC 8620 FilterOperator.
sub filter_match {
  my ($o, $f, $ctx) = @_;
  if (exists $f->{operator}) {
    my @c = @{ $f->{conditions} || [] };
    return (grep { !filter_match($o, $_, $ctx) } @c) ? 0 : 1 if $f->{operator} eq 'AND';
    return (grep {  filter_match($o, $_, $ctx) } @c) ? 1 : 0 if $f->{operator} eq 'OR';
    return (grep {  filter_match($o, $_, $ctx) } @c) ? 0 : 1;   # NOT
  }
  my $byid = $ctx->{byid};
  my $date = sub { epoch($_[0]) // 0 };
  if (exists $f->{isTopLevel})   { return 0 unless !defined $o->{parentId} == !!$f->{isTopLevel} }
  if (defined $f->{parentId})    { return 0 unless ($o->{parentId} // '') eq $f->{parentId} }
  if (defined $f->{ancestorId})  { return 0 unless grep { $_ eq $f->{ancestorId} } _ancestors($o->{id}, $byid) }
  if (defined $f->{descendantId}){ return 0 unless grep { $_ eq $o->{id} } _ancestors($f->{descendantId}, $byid) }
  if (defined $f->{nodeType})    { return 0 unless $o->{nodeType} eq $f->{nodeType} }
  if (defined $f->{role})        { return 0 unless ($o->{role} // '') eq $f->{role} }
  if (exists $f->{hasAnyRole})   { return 0 unless !!defined($o->{role}) == !!$f->{hasAnyRole} }
  if (defined $f->{blobId})      { return 0 unless ($o->{blobId} // '') eq $f->{blobId} }
  if (exists $f->{isExecutable}) { return 0 unless !!$o->{executable} == !!$f->{isExecutable} }
  for my $p (qw(created modified accessed)) {
    if (defined $f->{"${p}Before"}) { return 0 unless $date->($o->{$p}) <  $date->($f->{"${p}Before"}) }
    if (defined $f->{"${p}After"})  { return 0 unless $date->($o->{$p}) >= $date->($f->{"${p}After"}) }
  }
  if (defined $f->{minSize})     { return 0 unless defined $o->{size} && $o->{size} >= $f->{minSize} }
  if (defined $f->{maxSize})     { return 0 unless defined $o->{size} && $o->{size} <  $f->{maxSize} }
  if (defined $f->{name})        { return 0 unless $o->{name} eq $f->{name} }
  if (defined $f->{nameMatch})   { return 0 unless $o->{name} =~ glob_regex($f->{nameMatch}) }
  if (defined $f->{type})        { return 0 unless ($o->{type} // '') eq $f->{type} }
  if (defined $f->{typeMatch})   { return 0 unless ($o->{type} // '') =~ glob_regex($f->{typeMatch}) }
  if (defined $f->{text}) {
    my $g = glob_regex("*$f->{text}*");
    return 0 unless $o->{name} =~ $g || ($o->{type} // '') =~ $g;
  }
  return 1;
}

my %NODE_ORDER = (directory => 0, symlink => 1, file => 2);

sub sort_nodes {
  my ($objs, $sort, $byid) = @_;
  my %keys;
  my $cmp_one = sub {
    my ($c, $x, $y) = @_;
    my $p = $c->{property};
    my $r;
    if    ($p eq 'name')     { $r = JMAP::Collation::compare($c->{collation}, $x->{name}, $y->{name}, \%keys) }
    elsif ($p eq 'nodeType') { $r = $NODE_ORDER{$x->{nodeType}} <=> $NODE_ORDER{$y->{nodeType}} }
    elsif ($p eq 'type')     { $r = ($NODE_ORDER{$x->{nodeType}} <=> $NODE_ORDER{$y->{nodeType}})
                                 || JMAP::Collation::compare($c->{collation}, $x->{type} // '', $y->{type} // '', \%keys) }
    elsif ($p eq 'size')     { $r = (defined $x->{size} ? 0 : 1) <=> (defined $y->{size} ? 0 : 1) || ($x->{size} // 0) <=> ($y->{size} // 0) }
    else                     { $r = (epoch($x->{$p}) // 0) <=> (epoch($y->{$p}) // 0) }
    $r = -$r if defined $c->{isAscending} && !$c->{isAscending} && $p ne 'size';
    $r = ((defined $x->{size} ? 0 : 1) <=> (defined $y->{size} ? 0 : 1)) || (($y->{size} // 0) <=> ($x->{size} // 0))
      if $p eq 'size' && defined $c->{isAscending} && !$c->{isAscending};
    return $r;
  };
  my @flat = grep { ($_->{property} // '') ne 'tree' } @$sort;
  my $cmp = sub { my ($x, $y) = @_; for my $c (@flat) { my $r = $cmp_one->($c, $x, $y); return $r if $r } return $x->{id} cmp $y->{id} };
  return [ sort { $cmp->($a, $b) } @$objs ] unless grep { ($_->{property} // '') eq 'tree' } @$sort;

  # draft S3.2.5 "tree": by name, each directory followed by its sorted children
  my $tc = { property => 'name', collation => (grep { $_->{property} eq 'tree' } @$sort)[0]{collation} };
  my %in = map { $_->{id} => $_ } @$objs;
  my %kids;
  push @{ $kids{ defined $_->{parentId} && $in{$_->{parentId}} ? $_->{parentId} : '' } }, $_ for @$objs;
  my $order = sub { my ($x, $y) = @_; ($NODE_ORDER{$x->{nodeType}} <=> $NODE_ORDER{$y->{nodeType}}) || $cmp_one->($tc, $x, $y) || $x->{id} cmp $y->{id} };
  my @out;
  my $walk;
  $walk = sub { for my $n (sort { $order->($a, $b) } @{ $kids{$_[0]} || [] }) { push @out, $n; $walk->($n->{id}) } };
  $walk->('');
  return \@out;
}
```

Run `prove -l t/filenode-query.t` — PASS.

- [ ] **Step 3: The API methods (append to `JMAP/API/FileNode.pm`)**

```perl
sub _filenode_query_ids {
  my ($Self, $args) = @_;
  my $rows = $Self->{db}->filenode_rows();
  my %rowbyid = map { $_->{nodeid} => $_ } @$rows;
  my @objs = map { $Self->_filenode_object($_, \%rowbyid) } @$rows;
  my %byid = map { $_->{id} => $_ } @objs;
  my $ctx = { byid => \%byid };
  my $filter = $args->{filter};
  # draft S3.2.5 depth: "The number of levels of subdirectories to recurse
  # into".  With a top-level parentId condition P and depth d > 0, the query
  # covers P's descendants down to d levels below P's children: P's children
  # are level 0, their children level 1, and so on.
  my $depth = $args->{depth} // 0;
  if ($depth > 0 && ref $filter eq 'HASH' && !exists $filter->{operator} && defined $filter->{parentId}) {
    my %f = %$filter;
    my $base = delete $f{parentId};
    my @m = grep { JMAP::FileNode::filter_match($_, \%f, $ctx) } grep {
      my @a = JMAP::FileNode::_ancestors($_->{id}, \%byid);
      my ($i) = grep { $a[$_] eq $base } 0 .. $#a;
      defined $i && $i <= $depth;
    } @objs;
    return [ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@m, $args->{sort} || [], \%byid) } ];
  }
  my @m = grep { !$filter || JMAP::FileNode::filter_match($_, $filter, $ctx) } @objs;
  return [ map { $_->{id} } @{ JMAP::FileNode::sort_nodes(\@m, $args->{sort} || [], \%byid) } ];
}

sub api_FileNode_query {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my %ok = map { $_ => 1 } @{ $JMAP::FileNode::CAPS{fileNodeQuerySortOptions} };
  for my $c (@{ $args->{sort} || [] }) {
    return $Self->_transError(['error', {type => 'unsupportedSort', sort => $c}]) unless $ok{$c->{property} // ''};
  }
  my $ids = $Self->_filenode_query_ids($args);
  my $state = "$user->{jstateFileNode}";
  $Self->commit();
  $Self->{db}->save_query('FileNode', { filter => $args->{filter}, sort => $args->{sort}, depth => $args->{depth} }, $state, $ids);
  my ($start, $end) = $Self->_apply_window([ map { { id => $_ } } @$ids ], $args, sub { $_[0]{id} });
  return $Self->_transError(['error', {type => 'anchorNotFound'}]) unless defined $start;
  return ['FileNode/query', { accountId => $accountid, queryState => $state, canCalculateChanges => JSON::true,
                              position => $start + 0, total => scalar(@$ids), ids => [ @$ids[$start .. $end] ] }];
}

sub api_FileNode_queryChanges {
  my ($Self, $args) = @_;
  my ($user, $accountid) = $Self->_filenode_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;
  my $state = "$user->{jstateFileNode}";
  my $params = { filter => $args->{filter}, sort => $args->{sort}, depth => $args->{depth} };
  my $old = $Self->{db}->load_query('FileNode', $params, $args->{sinceQueryState} // '');
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $state}]) unless $old;
  my $since = $args->{sinceQueryState};
  my %changed = map { $_->{nodeid} => 1 } @{ $Self->{db}->dget('jfilenodes', { jmodseq => ['>', $since] }, 'nodeid') };
  my $new = $Self->_filenode_query_ids($args);
  $Self->commit();
  $Self->{db}->save_query('FileNode', $params, $state, $new);
  # every property is mutable, so a changed node is removed and re-added (RFC 8620 S5.6)
  my %oldset = map { $_ => 1 } @$old;
  my %newset = map { $_ => 1 } @$new;
  my @removed = grep { !$newset{$_} || $changed{$_} } @$old;
  my @added = map { { id => $new->[$_], index => $_ } } grep { !$oldset{$new->[$_]} || $changed{$new->[$_]} } 0 .. $#$new;
  return ['error', { type => 'tooManyChanges' }] if $args->{maxChanges} && @removed + @added > $args->{maxChanges};
  return ['FileNode/queryChanges', { accountId => $accountid, oldQueryState => $since, newQueryState => $state,
                                     removed => \@removed, added => \@added, total => scalar(@$new) }];
}
```

In `JMAP/API.pm`, add to `%FILTER_CONDITIONS`:

```perl
  'FileNode/query'        => \@FILENODE_FILTER,
  'FileNode/queryChanges' => \@FILENODE_FILTER,
```

with

```perl
my @FILENODE_FILTER = qw(isTopLevel parentId ancestorId descendantId nodeType role hasAnyRole
  blobId isExecutable createdBefore createdAfter modifiedBefore modifiedAfter accessedBefore
  accessedAfter minSize maxSize name nameMatch type typeMatch text);
```

(`body` is deliberately absent, so it is `unsupportedFilter`.) Add `depth => 'uint?'` checks by adding `'FileNode/query' => { depth => 'uint?', ... }` to `%PARAM_SCHEMA` only if other query arguments are listed there; otherwise validate `depth` in `api_FileNode_query` with `return invalidArguments` when it is not a non-negative integer.

- [ ] **Step 4: Integration (append to `t/filenode-webdav.t`) and run**

```perl
# --- query (Task 9)
my ($qq) = @{ jmap(['FileNode/query', { filter => { ancestorId => $home->{id} }, sort => [ { property => 'tree' } ] }]) };
ok(scalar @{$qq->{ids}}, 'tree query over the home directory');
my ($qb) = @{ jmap(['FileNode/query', { filter => { body => 'x' } }]) };
is($qb->{type}, 'unsupportedFilter', 'body filter is unsupported');

my ($qn) = @{ jmap(['FileNode/set', { create => { d1 => { parentId => $home->{id}, name => "$tag-deep" },
  d2 => { parentId => '#d1', name => 'd2' }, f3 => { parentId => '#d2', name => 'f3', blobId => $blob->{blobId} } } }]) };
my ($q0) = @{ jmap(['FileNode/query', { filter => { parentId => $qn->{created}{d1}{id} } }]) };
is_deeply($q0->{ids}, [ $qn->{created}{d2}{id} ], 'depth 0: children only');
my ($q1) = @{ jmap(['FileNode/query', { filter => { parentId => $qn->{created}{d1}{id} }, depth => 1 }]) };
is_deeply([ sort @{$q1->{ids}} ], [ sort $qn->{created}{d2}{id}, $qn->{created}{f3}{id} ], 'depth 1: one level further');
jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $qn->{created}{d1}{id} ] }]);
```

Run the unit and integration tests — PASS.

- [ ] **Step 5: Commit**

```bash
git add JMAP/FileNode.pm JMAP/API/FileNode.pm JMAP/API.pm t/filenode-query.t t/filenode-webdav.t
git commit -m "files: FileNode/query and /queryChanges"
```

---

### Task 10: Sharing — `shareWith` over WebDAV ACLs

**Files:**
- Modify: `JMAP/ImapDB.pm` (`filenode_sharewith`, `set_filenode_sharewith`)
- Modify: `JMAP/API/FileNode.pm` (`_filenode_object` fills `shareWith`; `update` path for `shareWith`)
- Test: `t/filenode-webdav.t` (extend)

**Interfaces:**
- Produces:
  - `ImapDB::filenode_sharewith($row) -> { userId => FilesRights }|undef` — from `files_get_acl`, ignoring `inherited` ACEs and the owner/`self`; principal href `/dav/principals/user/<name>/` maps to user id `<name>` (as calendar sharing does); `undef` when empty or when ACLs are unsupported.
  - `ImapDB::set_filenode_sharewith($row, \%shareWith) -> 1|0` — rewrites the non-inherited, non-owner ACEs: `mayRead → read`, `mayAddChildren → bind`, `mayDelete/mayRename → unbind`, `mayModifyContent → write-content`, `mayShare → write-acl`, keeping existing `self`/admin ACEs unchanged.

- [ ] **Step 1: Integration case (failing)**

```perl
# --- sharing (Task 10)
my ($sd) = @{ jmap(['FileNode/set', { create => { s => { parentId => $home->{id}, name => "$tag-shared" } } }]) };
my $sid = $sd->{created}{s}{id};
my ($ss) = @{ jmap(['FileNode/set', { update => { $sid => { shareWith => { user2 => { mayRead => JSON::true, mayAddChildren => JSON::false, mayRename => JSON::false, mayDelete => JSON::false, mayModifyContent => JSON::false, mayShare => JSON::false } } } } }]) };
ok(exists $ss->{updated}{$sid}, 'shareWith set') or diag explain $ss;
my $acl = $dav->GetAcl("$root/$tag-shared/");
ok((grep { $_->{principal} =~ m{/user2/$} && grep { $_ eq 'read' } @{$_->{grant}} } @$acl), 'an ACE for user2 with read') or diag explain $acl;
my ($sg) = @{ jmap(['FileNode/get', { ids => [ $sid ], properties => ['shareWith'] }]) };
ok($sg->{list}[0]{shareWith}{user2}{mayRead}, 'shareWith reads back');
jmap(['FileNode/set', { destroy => [ $sid ] }]);
```

Run — FAIL.

- [ ] **Step 2: Implement in `JMAP/ImapDB.pm`**

```perl
my %RIGHT2PRIV = (mayRead => 'read', mayAddChildren => 'bind', mayDelete => 'unbind', mayRename => 'unbind',
                  mayModifyContent => 'write-content', mayShare => 'write-acl');

sub _principal_user { my $h = shift // ''; return $h =~ m{/principals/(?:user/)?([^/]+)/?$} ? $1 : undef }

sub filenode_sharewith {
  my ($Self, $row) = @_;
  return undef unless $Self->filenode_features()->{acl};
  my $path = $row->{nodetype} eq 'directory' ? "$row->{href}/" : $row->{href};
  my $aces = eval { $Self->backend_cmd('files_get_acl', $path) } or return undef;
  $Self->begin();
  my $me = $Self->dgetfield('iserver', {}, 'username');
  $Self->commit();
  my %share;
  for my $ace (grep { !$_->{inherited} && $_->{principal} =~ m{^/} } @$aces) {
    my $uid = _principal_user($ace->{principal}) // next;
    next if $uid eq $me || $uid eq 'admin';
    my $r = JMAP::FileNode::rights($ace->{grant}, $ace->{grant});
    $share{$uid} = $r;
  }
  return %share ? \%share : undef;
}

sub set_filenode_sharewith {
  my ($Self, $row, $share) = @_;
  return 0 unless $Self->filenode_features()->{acl};
  my $path = $row->{nodetype} eq 'directory' ? "$row->{href}/" : $row->{href};
  my $aces = $Self->backend_cmd('files_get_acl', $path) or return 0;
  $Self->begin();
  my $me = $Self->dgetfield('iserver', {}, 'username');
  $Self->commit();
  my ($base) = map { $_->{principal} =~ m{^(.*/principals/(?:user/)?)} ? $1 : () } grep { $_->{principal} =~ m{^/} } @$aces;
  $base //= '/dav/principals/user/';
  my @keep = grep { !$_->{inherited} && !( $_->{principal} =~ m{^/} && do { my $u = _principal_user($_->{principal}); defined $u && $u ne $me && $u ne 'admin' } ) } @$aces;
  my @new = map { my $r = $share->{$_}; { principal => "$base$_/", grant => [ sort keys %{{ map { ($RIGHT2PRIV{$_} => 1) } grep { $r->{$_} } keys %RIGHT2PRIV }} ] } }
            grep { $share->{$_} } sort keys %{ $share || {} };
  my $status = $Self->backend_cmd('files_set_acl', $path, [ @keep, @new ]);
  return $status =~ /^2/ ? 1 : 0;
}
```

In `update_filenodes`, replace the Task 8 `shareWith` stub with:

```perl
    if (exists $p->{shareWith}) {
      unless ($Self->set_filenode_sharewith($byid{$id}, $p->{shareWith})) {
        $notupdated{$uid} = { type => 'invalidProperties', properties => ['shareWith'] }; next;
      }
      # descendants' derived myRights may change (draft "Access Control"): re-sync privileges below
      $Self->begin(); $Self->dupdate('iserver', { lastfilesync => 0 }); $Self->commit();
    }
```

In `_filenode_object`, set `shareWith` only when the caller has `mayShare` and asked for it: in `api_FileNode_get`, after building objects, for each object whose `myRights{mayShare}` is true and when `shareWith` is wanted (no `properties`, or it is listed), set `$o->{shareWith} = $Self->{db}->filenode_sharewith($rowbyid{$o->{id}})`.

- [ ] **Step 3: Run tests** — PASS. (`user2` is a default Cyrus test user.)

- [ ] **Step 4: Commit**

```bash
git add JMAP/ImapDB.pm JMAP/API/FileNode.pm t/filenode-webdav.t
git commit -m "files: shareWith over WebDAV ACLs"
```

---

### Task 11: FileNode/copy

**Files:**
- Modify: `JMAP/ImapDB.pm` (`copy_filenodes`)
- Modify: `JMAP/API/FileNode.pm` (`api_FileNode_copy` for the same-account case the parent forwards... see below)
- Modify: `JMAP/Dispatch.pm` (`%COPY_METHODS` gains `FileNode/copy`)
- Modify: `bin/jmap-proxy.pl` (`_do_copy_call` dispatch: `FileNode/copy`)
- Test: `t/filenode-webdav.t` (extend), `t/dispatch-copy-route.t` (existing)

**Interfaces:**
- Produces: `ImapDB::copy_filenodes(\%create, $from_rows_by_id, \%opts) -> (\%created, \%notCreated, \@alsoDestroyed)` for a copy within the account (WebDAV COPY, new ids). Cross-account copies reuse `_copy_objects`-style orchestration in the parent: fetch each source node's content with `fetch_blobs` (`d-` blob ids now resolve), then run `FileNode/set create` in the destination account with the new blob ids; directories are copied recursively by creating them parent-first with `#` references.

- [ ] **Step 1: Integration case (failing)**

```perl
# --- copy (Task 11)
my ($cs) = @{ jmap(['FileNode/set', { create => { d => { parentId => $home->{id}, name => "$tag-src" },
  f => { parentId => '#d', name => 'f.txt', blobId => $blob->{blobId} } } }]) };
my ($cp) = @{ jmap(['FileNode/copy', { fromAccountId => $user,
  create => { c => { id => $cs->{created}{d}{id}, parentId => $home->{id}, name => "$tag-copy" } } }]) };
ok($cp->{created}{c}{id}, 'same-account copy of a directory') or diag explain $cp;
isnt($cp->{created}{c}{id}, $cs->{created}{d}{id}, 'new id');
ok((grep { $_->{href} eq "$root/$tag-copy/f.txt" } @{ $dav->PropFind("$root/$tag-copy", 1) }), 'children copied on the server');
jmap(['FileNode/set', { onDestroyRemoveChildren => JSON::true, destroy => [ $cs->{created}{d}{id}, $cp->{created}{c}{id} ] }]);
```

Note: RFC 8620 `/copy` requires `fromAccountId` different from `accountId`; the draft's FileNode/copy also covers copying within an account. Run `_do_copy_call`'s existing `fromAccountId eq accountId` check against the draft before changing it: if the draft allows same-account FileNode/copy, route a same-account `FileNode/copy` to the worker's `api_FileNode_copy`; otherwise drop this test case and test cross-account copy only, using a `pool_account_pair` from the suite.

- [ ] **Step 2: Implement `copy_filenodes` (same account)**

```perl
sub copy_filenodes {
  my ($Self, $create, $idmap, $opts) = @_;
  my (%created, %notcreated, @also);
  for my $cid (sort keys %$create) {
    my $c = $create->{$cid};
    $Self->begin();
    my $src = $Self->filenode_row($idmap->($c->{id} // ''));
    my $parent = $Self->filenode_row($idmap->($c->{parentId} // ''));
    $Self->commit();
    unless ($src) { $notcreated{$cid} = { type => 'notFound' }; next }
    unless ($parent && $parent->{nodetype} eq 'directory') { $notcreated{$cid} = { type => 'invalidProperties', properties => ['parentId'] }; next }
    my $name = $c->{name} // $src->{name};
    if (my $why = JMAP::FileNode::name_problem($name)) { $notcreated{$cid} = { type => 'invalidProperties', properties => ['name'] }; next }
    my $isdir = $src->{nodetype} eq 'directory';
    my $dest = "$parent->{href}/$name";
    my $status = $Self->backend_cmd('files_copy', $isdir ? "$src->{href}/" : $src->{href}, $isdir ? "$dest/" : $dest,
                                    overwrite => (($opts->{onExists} // '') eq 'replace' ? 1 : 0));
    if ($status == 412) { $notcreated{$cid} = { type => 'alreadyExists' }; next }
    unless ($status =~ /^2/) { $notcreated{$cid} = { type => 'serverFail', description => "COPY: HTTP $status" }; next }
    # new nodes: a full sync of that subtree is the simplest correct refresh
    $Self->sync_files();
    $Self->begin();
    my $row = $Self->dgetone('jfilenodes', { href => $dest, active => 1 });
    $Self->commit();
    $created{$cid} = $row;
  }
  return (\%created, \%notcreated, \@also);
}
```

- [ ] **Step 3: Routing.** Add `FileNode/copy` to `%COPY_METHODS` in `JMAP/Dispatch.pm`. In `bin/jmap-proxy.pl`'s `_do_copy_call`, add a branch:

```perl
  elsif ($method eq 'FileNode/copy')     { _copy_filenodes($args, $from_aid, $to_aid, $tag, $cb, $errcb) }
```

Implement `_copy_filenodes` with the same fetch/store pattern as `_copy_emails`:

```perl
sub _copy_filenodes {
  my ($args, $from_aid, $to_aid, $tag, $cb, $errcb) = @_;
  my $create = $args->{create} || {};
  my $using = ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:filenode'];
  return $cb->(['FileNode/copy', { fromAccountId => $from_aid, accountId => $to_aid,
    oldState => undef, newState => undef, created => undef, notCreated => undef }, $tag]) unless %$create;

  # 1. every source node, with its whole subtree for directories (tree order:
  #    parents before children)
  my @src = map { $create->{$_}{id} } sort keys %$create;
  send_backend_request($from_aid, 'jmap', { using => $using, methodCalls => [
    ['FileNode/get', { accountId => $from_aid, ids => \@src }, 'g'],
    (map { ['FileNode/query', { accountId => $from_aid, filter => { ancestorId => $_ }, sort => [{ property => 'tree' }] }, "q$_"] } @src),
    (map { ['FileNode/get', { accountId => $from_aid, '#ids' => { resultOf => "q$_", name => 'FileNode/query', path => '/ids' } }, "s$_"] } @src),
  ] }, sub {
    my %r = map { $_->[2] => $_->[1] } @{ $_[0]{methodResponses} || [] };
    my %node = map { $_->{id} => $_ } map { @{ $_->{list} || [] } } grep { ref $_ eq 'HASH' && $_->{list} } values %r;
    my %notcreated;
    my @files = grep { $_->{nodeType} eq 'file' } values %node;
    # 2. content: d- blobs fetched from the source, stored in the destination
    send_backend_request($from_aid, 'fetch_blobs', { ids => [ map { $_->{blobId} } @files ] }, sub {
      my $blobs = shift;
      my @to_store = map { [ $_->{blobId}, $blobs->{$_->{blobId}} ] } grep { $blobs->{$_->{blobId}} } @files;
      my %newblob;
      my $finish = sub {
        # 3. one FileNode/set in the destination, parents before children via #refs
        my (%sets, %top_cid);
        for my $cid (sort keys %$create) {
          my $c = $create->{$cid};
          my $s = $node{$c->{id}} or do { $notcreated{$cid} = { type => 'notFound' }; next };
          $top_cid{$cid} = "c$cid";
          $sets{"c$cid"} = { parentId => $c->{parentId}, name => $c->{name} // $s->{name},
            ($s->{nodeType} eq 'file' ? (blobId => $newblob{$s->{blobId}}, type => $s->{type}) : ()),
            map { exists $c->{$_} ? ($_ => $c->{$_}) : () } qw(created modified accessed executable) };
          for my $d (@{ ($r{"s$c->{id}"} || {})->{list} || [] }) {
            $sets{"n$d->{id}"} = { parentId => ($d->{parentId} eq $c->{id} ? "#c$cid" : "#n$d->{parentId}"), name => $d->{name},
              ($d->{nodeType} eq 'file' ? (blobId => $newblob{$d->{blobId}}, type => $d->{type}) : ()) };
          }
        }
        send_backend_request($to_aid, 'jmap', { using => $using, methodCalls => [
          ['FileNode/set', { accountId => $to_aid, create => \%sets,
            (defined $args->{onExists} ? (onExists => $args->{onExists}) : ()) }, 's'] ] }, sub {
          my ($sr) = map { $_->[1] } grep { $_->[2] eq 's' } @{ $_[0]{methodResponses} || [] };
          my %created;
          for my $cid (keys %top_cid) {
            if (my $c = $sr->{created}{ $top_cid{$cid} })       { $created{$cid} = $c }
            elsif (my $e = $sr->{notCreated}{ $top_cid{$cid} }) { $notcreated{$cid} = $e }
          }
          my $copy = ['FileNode/copy', { fromAccountId => $from_aid, accountId => $to_aid,
            oldState => $sr->{oldState}, newState => $sr->{newState},
            created => %created ? \%created : undef, notCreated => %notcreated ? \%notcreated : undef }, $tag];
          return $cb->($copy) unless $args->{onSuccessDestroyOriginal} && %created;
          # RFC 8620 S5.4: the implicit /set carries the /copy's call id
          send_backend_request($from_aid, 'jmap', { using => $using, methodCalls => [
            ['FileNode/set', { accountId => $from_aid, onDestroyRemoveChildren => JSON::true,
              destroy => [ map { $create->{$_}{id} } keys %created ],
              (defined $args->{destroyFromIfInState} ? (ifInState => $args->{destroyFromIfInState}) : ()) }, 'd'] ] }, sub {
            my ($d) = grep { $_->[2] eq 'd' } @{ $_[0]{methodResponses} || [] };
            $cb->($d ? [$copy, [$d->[0], $d->[1], $tag]] : $copy);
          }, sub { $cb->($copy) });
        }, sub { $cb->(['error', { type => 'serverFail', description => $_[0] }, $tag]) });
      };
      my $next;
      $next = sub {
        return $finish->() unless @to_store;
        my ($old, $info) = @{ shift @to_store };
        send_backend_request($to_aid, 'store_blob', $info, sub { $newblob{$old} = shift->{blobId}; $next->() },
          sub { unlink $info->{path} if $info->{is_temp}; $next->() });
      };
      $next->();
    }, $errcb);
  }, $errcb);
}
```

Before relying on `fetch_blobs`/`store_blob`, read `_copy_emails` to confirm their argument and result shapes (`{ ids => [...] }` gives `{ blobId => info }`; storing `info` gives `{ blobId }`), and match them exactly.

- [ ] **Step 4: Run tests** — `prove -l t/dispatch-copy-route.t t/dispatch-method-capability.t` and the integration test. PASS.

- [ ] **Step 5: Commit**

```bash
git add JMAP/ImapDB.pm JMAP/API/FileNode.pm JMAP/Dispatch.pm bin/jmap-proxy.pl t/filenode-webdav.t
git commit -m "files: FileNode/copy, within an account and across accounts"
```

---

### Task 12: Quota, docs, and the JMAP-TestSuite FileNode tests

**Files:**
- Modify: `JMAP/API/Quota.pm` (FileNode in `types` when the server reports `quota-used-bytes`)
- Modify: `CLAUDE.md`, `ROADMAP.md`
- Create (in `~/src/JMAP-TestSuite`): `t/FileNode/get/basic.t`, `t/FileNode/set/create.t`, `t/FileNode/set/destroy.t`, `t/FileNode/set/update-move.t`, `t/FileNode/set/on-exists.t`, `t/FileNode/query/filters.t`, `t/FileNode/query/tree.t`, `t/FileNode/changes/basic.t`, and an entity class `lib/JMAP/TestSuite/Entity/FileNode.pm`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Quota.** If `filenode_features()->{quota}`, add a Quota object `{ id => 'files:octets', resourceType => 'octets', scope => 'account', name => <email>, types => ['FileNode'], used => quota-used-bytes, hardLimit => used + quota-available-bytes }` to `_get_all_quotas`, fetched with a Depth-0 PROPFIND of the root for `quota-used-bytes`/`quota-available-bytes` (add those two to `WebDAVTalk`'s `$PROPFIND_BODY` and `parse_multistatus` as `quotaUsed`/`quotaAvailable`, with a parse test case). Verify with `t/Quota/` in the suite.

- [ ] **Step 2: Docs.** In `CLAUDE.md` under "Code layout", add `JMAP/Sync/WebDAVTalk.pm`, `JMAP/FileNode.pm` and `JMAP/API/FileNode.pm` with one line each, and a short "FileNode over WebDAV" note: the mirror, `S`/`L` ids, the sync cadence (60 s on demand / 300 s background), the bogus-server defences, and that the test stack runs `<image>-webdav`. In `ROADMAP.md`, mark FileNode done and list the follow-ups: S/L id prefixes for every type; -15 xattrs/named streams; `onExists: unchanged` (JMAP-CONDITIONAL); PATCH writes.

- [ ] **Step 3: Suite tests.** In `~/src/JMAP-TestSuite`, follow the existing style (`use jmaptest; test { ... }`, `$account->tester`, `require_capabilities('urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:filenode')`, `pristine_account` for anything that creates named nodes). Each assertion cites the draft section it checks (memory: the suite is a spec test — assert only what the draft requires). Cover at minimum: the capability object's required keys and types; `FileNode/get` of the top-level node; create file/directory with server-set properties in `created`; `alreadyExists` with `existingId`; `onExists` replace/rename; `nodeHasChildren` and `onDestroyRemoveChildren` (all destroyed ids listed); move with cycle → `invalidProperties` on `parentId`; `nodeType` immutable; `fetchParents`; every query filter; `tree` sort; `/changes` after create/update/destroy. Commit there with its own messages.

- [ ] **Step 4: Full verification**

Run:
```bash
bin/restart-test-proxy.sh clean > /tmp/rt.log 2>&1
prove -l t/
CYRUS_URL=http://localhost:8080 CYRUS_USER=user1 CYRUS_PASS=password JMAP_PROXY_URL=http://localhost:9000 prove -l t/
bin/run-jmap-tests.sh > /tmp/suite.log 2>&1; grep -aE '^(Files|Result)' /tmp/jmap-test-results.txt
bin/run-jmap-tests.sh --direct > /tmp/direct.log 2>&1
```
Expected: every local test passes; no proxy-only failure outside `t/FileNode/` (compare with `--direct` as CLAUDE.md describes); every `t/FileNode/` test passes (Cyrus has no FileNode, so there is no `--direct` baseline for them).

- [ ] **Step 5: Commit**

```bash
git add JMAP/API/Quota.pm JMAP/Sync/WebDAVTalk.pm t/webdavtalk-parse.t CLAUDE.md ROADMAP.md
git commit -m "files: FileNode quota, documentation"
```
