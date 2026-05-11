# JMAP Proxy — Management API Reference

The management API runs on `JMAP_MGMT_PORT` (default `8080`, bound to
`127.0.0.1` by default). It is unauthenticated — keep it off the public
internet. The management dashboard at `http://localhost:8080/` uses this API.

All request and response bodies are JSON (`Content-Type: application/json`).

---

## Health & Metrics

### `GET /healthz`

Returns the current process status.

**Response 200**
```json
{
  "status":   "ok",
  "uptime":   3600,
  "children": 2,
  "pid":      12345
}
```

| Field | Description |
|---|---|
| `status` | Always `"ok"` if the process is alive. |
| `uptime` | Seconds since the proxy started. |
| `children` | Number of live per-account worker processes (excludes `__accounts__`). |
| `pid` | OS process ID of the parent. |

---

### `GET /metrics`

Returns Prometheus-format metrics (`text/plain; version=0.0.4`).

```
# HELP jmap_uptime_seconds Seconds since proxy process started
# TYPE jmap_uptime_seconds gauge
jmap_uptime_seconds 3600

# HELP jmap_backend_workers_active Active per-account backend worker processes
# TYPE jmap_backend_workers_active gauge
jmap_backend_workers_active 2

# HELP jmap_http_requests HTTP requests received on the JMAP port
# TYPE jmap_http_requests counter
jmap_http_requests_total 4182

# HELP jmap_account_last_sync_age_seconds Seconds since last successful sync per account
# TYPE jmap_account_last_sync_age_seconds gauge
jmap_account_last_sync_age_seconds{accountid="alice"} 28
jmap_account_last_sync_age_seconds{accountid="bob"} 12
```

Full metric list: see the Monitoring section of [SETUP.md](SETUP.md).

---

## Accounts

### `GET /api/accounts`

Lists all registered accounts with basic statistics.

**Response 200**
```json
[
  {
    "accountid": "alice",
    "email":     "alice@example.com",
    "type":      "imap",
    "imapHost":  "imap.example.com",
    "imapPort":  993,
    "folders":   42,
    "messages":  1830
  }
]
```

| Field | Description |
|---|---|
| `accountid` | Unique identifier for the account. |
| `email` | Email address. |
| `type` | `"imap"` or `"jmap"`. |
| `imapHost` | IMAP hostname (IMAP accounts only). |
| `imapPort` | IMAP port (IMAP accounts only). |
| `folders` | Number of synced folders. |
| `messages` | Number of synced messages. |

---

### `GET /api/accounts/:accountid`

Returns details for a single account.

**Response 200** — same shape as one element of the `GET /api/accounts` list.

**Response 404**
```json
{ "error": "not found" }
```

---

### `POST /api/accounts`

Creates and initialises a new account.

#### IMAP account

```json
{
  "accountid":  "alice",
  "email":      "alice@example.com",
  "type":       "imap",
  "username":   "alice@example.com",
  "password":   "secret",
  "imapHost":   "imap.example.com",
  "imapPort":   993,
  "imapSSL":    2,
  "smtpHost":   "smtp.example.com",
  "smtpPort":   587,
  "smtpSSL":    3,
  "caldavURL":  "https://dav.example.com",
  "carddavURL": "https://dav.example.com"
}
```

| Field | Required | Description |
|---|---|---|
| `accountid` | **yes** | Unique identifier. Alphanumeric, no spaces. |
| `email` | **yes** | Email address shown to JMAP clients. |
| `type` | no | `"imap"` (default). |
| `username` | no | IMAP login name. Defaults to `email`. |
| `password` | no | IMAP password or app-specific password. |
| `imapHost` | no | IMAP server hostname. If omitted, SRV DNS discovery is attempted. |
| `imapPort` | no | IMAP port. Default `993`. |
| `imapSSL` | no | `0`=plain, `2`=TLS, `3`=STARTTLS. Default `2`. |
| `smtpHost` | no | SMTP server hostname. |
| `smtpPort` | no | SMTP port. Default `587`. |
| `smtpSSL` | no | `0`=plain, `2`=TLS, `3`=STARTTLS. Default `3`. |
| `caldavURL` | no | CalDAV base URL for calendar sync. |
| `carddavURL` | no | CardDAV base URL for contacts sync. |

**Response 201**
```json
{ "accountid": "alice", "type": "imap" }
```

If the account was created but the initial IMAP sync failed:
```json
{
  "accountid": "alice",
  "type":      "imap",
  "warning":   "setup failed: Connection refused"
}
```
The account still exists; you can trigger a sync manually once the backend
is reachable.

#### JMAP passthrough account

```json
{
  "accountid":  "bob",
  "email":      "bob@example.com",
  "sessionUrl": "https://jmap.example.com/session",
  "username":   "bob@example.com",
  "password":   "secret",
  "authType":   "basic"
}
```

| Field | Required | Description |
|---|---|---|
| `accountid` | **yes** | Unique identifier. |
| `email` | **yes** | Email address. |
| `sessionUrl` | **yes** | URL of the upstream JMAP Session object (`/.well-known/jmap` or direct). |
| `username` | no | Username for authenticating to the upstream. |
| `password` | no | Password or Bearer token. |
| `authType` | no | `"basic"` (default) or `"bearer"`. |

**Response 201**
```json
{ "accountid": "bob", "type": "jmap", "email": "bob@example.com" }
```

Note: for JMAP passthrough accounts the proxy fetches the upstream Session to
discover the real `accountId`, which may differ from the `accountid` you provide.
The response contains the canonical `accountid` to use in subsequent calls.

**Error responses**

| Status | Body | Meaning |
|---|---|---|
| 400 | `{"error":"invalid JSON"}` | Request body was not valid JSON. |
| 400 | `{"error":"accountid required"}` | `accountid` field missing. |
| 500 | `{"error":"<message>"}` | Backend error during setup. |

---

### `DELETE /api/accounts/:accountid`

Deletes an account and all its local data.

This stops the per-account worker, removes the account from `accounts.sqlite3`,
and deletes the per-account SQLite database file. Emails and calendar data
on the remote backend are **not** affected.

**Response 200**
```json
{ "deleted": true }
```

**Response 404** — if the account does not exist (returned by the accounts child).

---

### `POST /api/accounts/:accountid/sync`

Triggers an immediate IMAP/CalDAV/CardDAV sync for the account. The sync runs
in the account's worker process; this call returns once the sync completes.

For JMAP passthrough accounts this is a no-op (no local sync state).

**Response 200**
```json
{ "synced": "alice" }
```

**Response 500**
```json
{ "error": "IMAP connection refused" }
```

---

## JMAP Endpoint

The following endpoints are on `JMAP_PORT` (default `9000`) and require
authentication (Basic, Bearer, or cookie).

### `GET /.well-known/jmap`

Redirects (301) to `$BASEURL/session`.

### `GET /session`

Returns the JMAP Session object (RFC 8620 §2). The response includes:
- All accounts in the authenticated user's pool
- Capability declarations for core, mail, calendars, contacts, quota, principals
- URLs for API, upload, download, event source

### `POST /jmap`

Main JMAP API endpoint (RFC 8620 §3). Accepts a `Request` object:
```json
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
  "methodCalls": [["Email/get", {"ids": ["abc"]}, "r1"]]
}
```

Cross-account `/copy` methods (`Blob/copy`, `Email/copy`, `CalendarEvent/copy`,
`ContactCard/copy`) are handled at the parent level and can address any two
accounts within the same account pool.

### `POST /upload/:accountid`

Blob upload (RFC 8620 §6.1). `Content-Type` header sets the blob MIME type.
Returns:
```json
{
  "accountId": "...",
  "blobId":    "f-<uuid>",
  "type":      "image/jpeg",
  "size":      12345
}
```

### `GET /raw/:accountid/:blobId/:name`

Blob download (RFC 8620 §6.2). `name` is used as the `Content-Disposition`
filename. Requires authentication.

### `GET /eventsource`

Server-Sent Events push channel (RFC 8620 §7.3).

Query parameters:
- `types`: comma-separated list of data-type names to watch (e.g. `Email,Mailbox`)
- `closeafter`: `state` to close after first `StateChange` event, or `no` (default)
- `ping`: client-requested ping interval in seconds (minimum 30, default 300)

Events:
- `state` — `StateChange` object (RFC 8620 §7.1) when any watched type changes
- `ping` — keepalive with `{"interval": N}`

---

## OAuth2 Endpoints

These endpoints handle the web-based sign-up and OAuth2 flows. They live on
`JMAP_PORT` and serve the user-facing UI.

| Path | Description |
|---|---|
| `GET /` | Landing page and self-service sign-up form |
| `GET /accounts` | Authenticated account management page (add, edit, detach, delete accounts; manage tokens) |
| `GET /cb/oauth` | OAuth2 callback — receives `code` from Google/Fastmail after authorisation |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 OAuth2 server metadata (for OIDC clients) |
| `GET /oauth/jwks` | OIDC JSON Web Key Set (RS256 public key) |

---

## Error Responses

All management API errors return JSON:

```json
{ "error": "human-readable message" }
```

Standard HTTP status codes apply: `400` bad request, `404` not found,
`500` internal error.

JMAP-level errors (on `POST /jmap`) follow RFC 8620 §3.6:
```json
{
  "type":        "urn:ietf:params:jmap:error:notJSON",
  "status":      400,
  "detail":      "..."
}
```
