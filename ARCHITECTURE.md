# JMAP Proxy Architecture

## Process Model

```
PARENT (event loop - NEVER BLOCKS)
  |-- AnyEvent::HTTPD on JMAP_PORT
  |     \-- do_jmap/do_upload/do_raw -> send_backend_request() -> callback
  |-- AnyEvent::HTTPD on JMAP_MGMT_PORT
  |     \-- mgmt_api_accounts -> send_backend_request() -> callback
  |-- %backend: name -> [AnyEvent::Handle to child, cmd_counter]
  |-- %waiting: name -> { tag -> [success_cb, error_cb] }
  \-- SIGCHLD reaper

CHILD: __accounts__ (forked on first mgmt request, blocking loop)
  |-- Startup: open accounts.sqlite3
  |-- Loop: sysread JSON -> process command -> syswrite JSON response
  |     Commands: list_accounts, get_account, create_account, delete_account
  \-- Manages ONLY accounts.sqlite3 + reads per-account DB stats

CHILD: per-account (forked on first request to accountid, blocking loop)
  |-- Startup: look up account in accounts.sqlite3, create ImapDB/API
  |-- Loop: sysread JSON -> process command -> syswrite JSON response
  |     Commands: jmap, upload, download, raw, sync, davsync,
  |               setup, delete, ping, getinfo
  \-- Exit on error or delete
```

## The Rule

- **Parent**: HTTP routing, request dispatch, response callbacks, child management
- **Child (__accounts__)**: accounts.sqlite3 reads/writes, per-account DB stat reads
- **Child (per-account)**: ALL IMAP/CalDAV/CardDAV, per-account SQLite, sync, JMAP methods
- **NEVER in parent**: `firstsync`, `sync_imap`, `sync_folders`, IMAP connections,
  `JMAP::ImapDB->new()`, `setuser()`, per-account DB operations, DBI->connect

## Account Creation Flow

```
Client -> POST /api/accounts {accountid, imapHost, username, password, ...}
  Parent:
    1. $httpd->stop_request()
    2. send_backend_request('__accounts__', 'create_account', $data, ...)
       -> forks __accounts__ child via get_backend() if needed
  __accounts__ child:
    3. INSERT INTO accounts.sqlite3 (email, accountid, type)
    4. Writes ['create_account', {accountid, type}, tag]
  Parent callback:
    5. send_backend_request($accountid, 'setup', $data, ...)
       -> forks per-account child via get_backend()
  Per-account child:
    6. run_backend_worker() starts, but account has no iserver config yet
    7. Reads 'setup' command
    8. Calls $db->setuser($args)
    9. Calls $db->firstsync()
    10. Calls $db->sync_imap()
    11. Writes ['setup', true, tag]
  Parent callback:
    12. Responds HTTP 201 to client
```

## Docker Container

- Single entry point: `jmap-proxy.pl` (parent forks children internally)
- `docker-entrypoint.sh`: init `accounts.sqlite3`, exec jmap-proxy.pl
- Ports: `JMAP_PORT` (public), `JMAP_MGMT_PORT` (management, localhost-only by default)
- Volume: `/data` -- `accounts.sqlite3` + per-account `.sqlite3` files
- Env: `JMAP_PORT`, `JMAP_MGMT_PORT`, `JMAP_MGMT_HOST`, `JMAP_DATADIR`, `BASEURL`
