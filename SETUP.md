# JMAP Proxy — Setup Guide

## Overview

The JMAP proxy bridges IMAP/CalDAV/CardDAV backends to the JMAP protocol
(RFC 8620/8621, JMAP Calendars, JMAP Contacts). It also supports direct
JMAP-to-JMAP passthrough for backends that already speak JMAP natively.

```
JMAP client  ──JMAP──►  jmap-proxy  ──IMAP/CalDAV/CardDAV──►  mail server
                                    ──JMAP──────────────────►  JMAP server
```

---

## Quick Start (Docker)

```bash
docker run -d \
  --name jmap-proxy \
  --restart unless-stopped \
  -p 127.0.0.1:9000:9000 \
  -p 127.0.0.1:8080:8080 \
  -e JMAP_MGMT_HOST=0.0.0.0 \
  -v /data/jmap-proxy:/data \
  -e BASEURL=https://jmap.example.com \
  ghcr.io/jmapio/jmap-proxy:latest
```

- **Port 9000**: JMAP endpoint, plain HTTP: published on loopback for a TLS reverse proxy on the host
- **Port 8080**: Management API (keep localhost-only; inside the container it must bind `0.0.0.0` for the mapping to reach it, and every request needs the management token, see `JMAP_MGMT_TOKEN`)
- The container runs the proxy as an unprivileged `jmap` user (uid 10001) and hands it `/data` at start; `JMAP_RUN_AS_ROOT=1` keeps it root
- **`/data`**: persistent volume for SQLite databases

Browse to `http://localhost:8080` to open the management dashboard.

---

## Prerequisites

### Docker deployment

- Docker Engine 20+
- A domain name with DNS pointing at your server
- A reverse proxy for TLS (Caddy or nginx — see [TLS Termination](#tls-termination))

### Running from source

```bash
# Perl 5.20+, then:
cpanm --installdeps .
perl bin/jmap-proxy.pl
```

---

## Environment Variables

All variables are optional unless marked **required**.

| Variable | Default | Description |
|---|---|---|
| `BASEURL` | `http://localhost:9000` | **Required for production.** Public URL the proxy is reachable at. Used in JMAP Session URLs and OAuth redirect URIs. |
| `JMAP_PORT` | `9000` | Port for the JMAP endpoint. |
| `JMAP_MGMT_PORT` | `8080` | Port for the management API and dashboard. |
| `JMAP_MGMT_HOST` | `127.0.0.1` | Interface the management port binds to. Set to `0.0.0.0` only if you have external access controls. |
| `JMAP_DATADIR` | `/data` | Directory for SQLite databases (`accounts.sqlite3` + per-account files). |
| `JMAP_HOME` | `/home/jmap/jmap-perl` | Directory containing the proxy source. Set automatically in Docker. |
| `JMAP_IDLE_TIMEOUT` | `300` | Seconds of inactivity before a per-account worker is killed. Set to `0` to disable. |
| `JMAP_WORKER_TIMEOUT` | `1800` | Seconds a worker with requests waiting may go without answering before it is killed and those requests fail (a read from a server that never answers). `0` disables. |
| `JMAP_OIDC_CLIENTS` | (none) | The OpenID Connect clients (e.g. a webmail doing SSO) the proxy issues codes to: a JSON object `{"client_id": ["https://exact/redirect/uri", ...]}`. Redirect URIs match exactly; clients must use PKCE (S256) and send `client_id`, `redirect_uri` and `code_verifier` to `/oauth/token`. Unset, `/oauth/authorize` and `/oauth/token` are off. |
| `JMAP_MGMT_TOKEN` | generated | The management API's token: send it as `Authorization: Bearer <token>` (or as the password of Basic auth, for the dashboard in a browser). Unset, one is generated on first start into `$JMAP_DATADIR/mgmt-token` (mode 0600). `/healthz` and `/metrics` need none. |
| `JMAP_ALLOW_PRIVATE_BACKENDS` | (unset) | Every server a user names (IMAP, SMTP, CalDAV/CardDAV/WebDAV, a JMAP upstream and the URLs its session lists, autodiscovery) must be at a public address: a worker refuses to connect to loopback, private, link-local or similar addresses, so a user cannot make the proxy reach its own management API or the network behind it. Set to `1` when the mail servers are on the proxy's own network. |
| `JMAP_PRIVATE_ALLOW` | (none) | Private addresses that are allowed anyway, comma-separated, with optional prefix lengths: e.g. an OpenBao server, or one internal IMAP host (`10.0.0.5,192.168.1.0/24,fd00::/8`). |
| `JMAP_PDPA_MAX_BYTES` | `200000000` | The largest PDPA archive `POST /pdpa` accepts. Every request body has a limit, checked against its Content-Length before any of it is read: `/jmap` 10 MB, `/upload` 50 MB, `/filenode` `JMAP_FILES_MAX_BYTES`, anything else 1 MB (413 over it). |
| `JMAP_PDPA_MAX_UNZIPPED` | `500000000` | How much a PDPA import may inflate to (a zip bomb is stopped while it is read). |
| `JMAP_AUTH_FAIL_MAX` | `20` | Failed password logins (Basic auth, the OpenID Connect form) one client address may make in 15 minutes before it is answered 429 until the window passes. The address is the connecting peer, or, from a reverse proxy, the last X-Forwarded-For entry not itself a proxy (see `JMAP_TRUSTED_PROXIES`). |
| `JMAP_TRUSTED_PROXIES` | *(unset)* | Comma-separated addresses of the reverse proxies whose X-Forwarded-For is believed. Unset, any peer on a loopback or private address is taken to be one; a client connecting from a public address never sets its own address. |
| `JMAP_SIGNUP_MAX` | `30` | Attempts at the signup and login forms (`/signup`, `/signup_jmap`) one client address may make in an hour, whatever their outcome; then 429. `0` turns the limit off. |
| `JMAP_TOKEN_IDLE_DAYS` | `90` | A session or bearer token not used for this many days stops working and is deleted when next presented. `0` keeps tokens for ever. |
| `JMAP_SSE_PER_ACCOUNT` | `20` | EventSource connections one login may hold; a new one beyond this closes its oldest. `0` turns the limit off. |
| `IGNORE_INVALID_CERT` | *(unset)* | Set to turn off TLS certificate checks for IMAP and every HTTPS request (DAV, upstream JMAP, OAuth, discovery). Only for a test server with a self-signed certificate. |
| `JMAP_DEBUG` | *(unset)* | Logs every JMAP request and response body in full: mail content, addresses, calendar and contact data go to the log. For debugging only; never on a server with other people's mail. |
| `DEBUGDB` | *(unset)* | Logs every SQL statement and its bound values, and the rows read (credential columns masked). Even more than `JMAP_DEBUG`: for debugging only. |
| `JMAP_SYNC_INTERVAL` | `30` | Seconds between background IMAP/CalDAV/CardDAV sync polls. |
| `JMAP_IMAP_TIMEOUT` | `120` | Seconds of silence after which an IMAP connection counts as dead. Counts from the last data received, so slow downloads aren't cut off. |
| `JMAP_FILES_DROPPABLE_PRINCIPALS` | _(empty)_ | Comma-separated user principal names (a bare name matches only the user principal of that name) or whole principal hrefs (matched exactly) whose ACEs FileNode sharing may drop when the WebDAV server refuses to take back an ACE it lists itself (`DAV:recognized-principal`; Cyrus lists principals it cannot resolve, such as an `admin` from `defaultacl`). Each drop is logged. Anything not listed makes the share fail (`serverFail`) and leaves the ACL alone. The test stack sets `admin`. |
| `JMAP_FILES_MAX_BYTES` | `268435456` (256 MiB) | The most bytes of one file's content the proxy holds in memory for FileNode: a direct PUT over it is refused with 413 before the body reaches a worker, a download of a bigger file's blob is 501, and a cross-account `FileNode/copy` of one fails that item with `serverFail` naming the limit (a `FileNode/set` from such a blob is `tooLarge`). Content is not streamed yet. |
| `JMAP_DISABLE_SIGNUP` | _(unset)_ | Set to `1`/`true` to block self-service creation of **new** accounts on `/signup`, `/signup_jmap` and `/cb/oauth`. Existing accounts are unaffected: their users log in as before, and an OAuth sign-in that proves ownership of the address can still renew an account's refresh token. The management API (`POST /api/accounts`) is deliberately **not** affected, passthrough accounts included — that stays the admin path for adding users while public signup is closed. Empty, `0`, `false`, `no` and `off` (any case) leave signup open. |
| `JMAP_SECRET_KEY` | _(unset)_ | 64 hex chars (a 256-bit key) for credential encryption. Required, unless OpenBao is used or `JMAP_ALLOW_PLAINTEXT_CREDENTIALS` is set. |
| `JMAP_ALLOW_PLAINTEXT_CREDENTIALS` | _(unset)_ | Set to `1` to store credentials in plaintext when no key is configured (a test server). Without it the proxy refuses to start. |
| `JMAP_OPENBAO_ADDR` | _(unset)_ | OpenBao/Vault address for Transit-based credential encryption (e.g. `http://vault:8200`). |
| `JMAP_OPENBAO_TOKEN` | _(unset)_ | Static OpenBao token (simpler; prefer AppRole for production). |
| `JMAP_OPENBAO_ROLE_ID` | _(unset)_ | OpenBao AppRole role ID (for AppRole auth). |
| `JMAP_OPENBAO_SECRET_ID` | _(unset)_ | OpenBao AppRole secret ID. |
| `JMAP_OPENBAO_MOUNT` | `transit` | OpenBao secrets engine mount point. |
| `JMAP_OPENBAO_KEY` | `jmap-credentials` | Transit key name inside the mount. |
| `GOOGLE_CLIENT_ID` | _(unset)_ | OAuth2 client ID for Gmail accounts. |
| `GOOGLE_CLIENT_SECRET` | _(unset)_ | OAuth2 client secret for Gmail accounts. |
| `FASTMAIL_CLIENT_ID` | _(unset)_ | OAuth2 client ID for Fastmail accounts (uses built-in ID if unset). |

---

## TLS Termination

The proxy speaks plain HTTP. Put a reverse proxy in front.

### Caddy (recommended — automatic TLS via Let's Encrypt)

```
jmap.example.com {
    reverse_proxy 127.0.0.1:9000
}
```

### nginx

```nginx
server {
    listen 443 ssl;
    server_name jmap.example.com;

    ssl_certificate     /etc/ssl/certs/jmap.pem;
    ssl_certificate_key /etc/ssl/private/jmap.key;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 50m;
    }
}
```

---

## Adding Accounts

### Via the web UI

Browse to `http://localhost:8080` and use the management dashboard. It supports
adding IMAP, CalDAV/CardDAV, and JMAP passthrough accounts.

### Via the management API

```bash
# IMAP account with CalDAV/CardDAV
curl -X POST http://localhost:8080/api/accounts \
  -H 'Content-Type: application/json' \
  -d '{
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
  }'

# JMAP passthrough account
curl -X POST http://localhost:8080/api/accounts \
  -H 'Content-Type: application/json' \
  -d '{
    "accountid":  "bob",
    "email":      "bob@example.com",
    "sessionUrl": "https://api.example.com/jmap",
    "username":   "bob@example.com",
    "password":   "secret",
    "authType":   "basic"
  }'
```

**SSL/TLS values** for `imapSSL` / `smtpSSL`:

| Value | Meaning |
|---|---|
| `0` | Plain (no encryption) |
| `1` | Plain (alias for 0) |
| `2` | SSL/TLS from the start (IMAPS, port 993) |
| `3` | STARTTLS upgrade (IMAP STARTTLS, port 143 or 587) |

### Via the sign-up form

The web UI at `$BASEURL/` includes a sign-up form for self-service account
registration. Users enter their email address; the proxy performs SRV DNS
auto-discovery for IMAP/SMTP and PACC (draft-ietf-mailmaint-pacc) for OAuth2
providers, then redirects to OAuth or a password form as appropriate.
CalDAV/CardDAV are found per RFC 6764: SRV records (with the TXT `path`) if the
domain has them, otherwise `/.well-known/caldav` and `/.well-known/carddav` on
the mail domain and then on the IMAP host. A guessed URL is only kept when the
user's login finds a principal there over HTTPS with a valid certificate.

---

## OAuth2 Setup

### Gmail

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable the **Gmail API**, the **CalDAV API** (`caldav.googleapis.com`) and the
   **Google Contacts CardDAV API** (`carddav.googleapis.com`). Calendars and contacts
   are synced over CalDAV/CardDAV, so without these two every sync fails with
   `403 accessNotConfigured` / `SERVICE_DISABLED` while mail keeps working.
3. Create an OAuth2 credential (web application type).
4. Add `$BASEURL/cb/oauth` as an authorised redirect URI.
5. Set the environment variables:

```
GOOGLE_CLIENT_ID=<your-client-id>.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=<your-client-secret>
```

### Fastmail

Fastmail uses PKCE OAuth2 — no client secret needed.

```
FASTMAIL_CLIENT_ID=<your-client-id>
```

If `FASTMAIL_CLIENT_ID` is not set, the proxy uses a built-in app registration
that works for testing but may have rate limits.

---

## Credential Encryption

IMAP/SMTP passwords and OAuth tokens are stored in SQLite, encrypted: the
proxy will not start without `JMAP_SECRET_KEY` or OpenBao, unless
`JMAP_ALLOW_PLAINTEXT_CREDENTIALS=1` says plaintext is meant (a test server).

Each credential is encrypted with associated data naming its account and
field, so one copied into another account's database does not decrypt.

### AES-256-GCM (single-server)

```bash
# Generate a key
openssl rand -hex 32
```

```
JMAP_SECRET_KEY=<64-hex-chars>
```

It must be a 256-bit key, 64 hex characters; a passphrase is refused. The
encryption key and the key for credential fingerprints are derived from it
with HKDF-SHA256, apart. Values are stored as `enc2:`.

Keep the key separate from the data volume. Losing the key means losing
access to all stored credentials.

### OpenBao / Vault Transit (multi-server / production)

Keys never leave OpenBao; the proxy only ever holds ciphertexts.

```bash
# Dev mode — use proper storage in production
docker run -d --name openbao \
  -e VAULT_DEV_ROOT_TOKEN_ID=mytoken \
  -p 8200:8200 quay.io/openbao/openbao:latest

export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=mytoken
bao secrets enable transit
bao write transit/keys/jmap-credentials type=aes256-gcm96
```

```
# Option A: static token
JMAP_OPENBAO_ADDR=http://openbao:8200
JMAP_OPENBAO_TOKEN=mytoken

# Option B: AppRole (recommended)
JMAP_OPENBAO_ADDR=http://openbao:8200
JMAP_OPENBAO_ROLE_ID=<role-id>
JMAP_OPENBAO_SECRET_ID=<secret-id>
```

### Migration

Encrypted and plaintext credentials can coexist. To migrate:

1. Set `JMAP_SECRET_KEY` (or `JMAP_OPENBAO_*`) and restart.
2. Credentials are re-encrypted the next time each account syncs.
3. To force all accounts immediately, trigger a settings update via the
   management API.

When migrating from AES to OpenBao, keep `JMAP_SECRET_KEY` set until all
accounts have been re-encrypted — `enc2:` values are read with it.

Credentials stored by versions before 2026-11 (`enc1:`: one key for both
encryption and fingerprints, derived from a passphrase by a single
SHA-256, no associated data) are no longer read: those accounts are set up
again. The OpenBao transit key must be an AEAD key (`aes256-gcm96`), which
takes the associated data.

---

## Connecting JMAP Clients

After setup, point any RFC 8620-compliant JMAP client at:

```
GET $BASEURL/.well-known/jmap
```

This redirects to the Session object at `$BASEURL/session`.

**Authentication**: Basic (`email:password`), Bearer token, or session cookie.
Clients that follow RFC 8620 auto-discovery will find everything from the
session URL.

**Recommended clients**:
- [Bulwark](https://github.com/nicholasgasior/bulwark) — web-based
- [TMail](https://github.com/linagora/tmail-flutter) — mobile
- [aerc](https://aerc-mail.org/) — terminal

---

## Monitoring

### Health check

```bash
curl http://localhost:8080/healthz
# {"status":"ok","uptime":3600,"children":2,"pid":12345}
```

### Prometheus metrics

```bash
curl http://localhost:8080/metrics
```

Key metrics:

| Metric | Type | Description |
|---|---|---|
| `jmap_uptime_seconds` | gauge | Seconds since the proxy started |
| `jmap_backend_workers_active` | gauge | Live per-account worker processes |
| `jmap_backend_queue_depth` | gauge | Pending backend requests |
| `jmap_sse_connections_active` | gauge | Open Server-Sent Events connections |
| `jmap_http_requests_total` | counter | JMAP port requests |
| `jmap_method_calls_total` | counter | Individual JMAP method calls |
| `jmap_method_errors_total` | counter | Method calls returning an error |
| `jmap_account_last_sync_age_seconds` | gauge | Per-account sync lag (labelled by `accountid`) |

---

## Troubleshooting

**Proxy not responding**  
Check `docker logs jmap-proxy` (or `/tmp/jmap-proxy.log` when running from
source). The proxy logs fatal errors and per-account sync warnings to stderr.

**Account sync failing**  
Trigger a manual sync and watch for errors:
```bash
curl -X POST http://localhost:8080/api/accounts/ACCOUNTID/sync
docker logs -f jmap-proxy
```

**JMAP requests returning wrong URLs**  
`BASEURL` must match the public URL the client reaches. If it defaults to
`http://localhost:9000`, all session URLs will be wrong.

**Debug mode**  
Set `JMAP_DEBUG=1` to log full request/response JSON to stderr. Do not leave
it on in production: it puts the mail, calendars and contacts that pass through
in the log.

**SSE push not working behind nginx**  
Add `proxy_buffering off` and `proxy_read_timeout 3600` to the nginx location
block, and ensure `X-Accel-Buffering: no` is passed through.
