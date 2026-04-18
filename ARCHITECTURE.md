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

## Lifecycle

- **Health check**: `GET /healthz` on `JMAP_MGMT_PORT` -- returns uptime, child count, pid
- **Idle timeout**: children with no activity for `JMAP_IDLE_TIMEOUT` seconds (default 300)
  are closed by the parent. The `__accounts__` child is exempt. Set to 0 to disable.
- **Graceful shutdown**: SIGTERM/SIGINT stops accepting connections, closes all children
  (they exit on socketpair EOF), and exits after 2 seconds.

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
- Env: `JMAP_PORT`, `JMAP_MGMT_PORT`, `JMAP_MGMT_HOST`, `JMAP_DATADIR`, `BASEURL`,
  `JMAP_IDLE_TIMEOUT`

## OAuth2 Setup

The signup flow auto-discovers whether a mail provider requires OAuth2 (via PACC,
Mozilla autoconfig, or hardcoded provider lists) and redirects users accordingly.
OAuth2 providers require per-deployment app registration.

### Gmail

1. Go to [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials
2. Create an OAuth 2.0 Client ID (type: **Web application**)
3. Add `https://YOUR_DOMAIN/cb/oauth` as an **Authorized redirect URI**
4. Enable the **Gmail API** and **Google Calendar API** and **CardDAV API** for your project
5. Set environment variables in your Docker run command or `.env`:

```
GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=your-client-secret
```

The redirect URI defaults to `$BASEURL/cb/oauth`. Override with `GOOGLE_REDIRECT_URI`
if needed (must match what you registered with Google).

When both env vars are set, `@gmail.com` and `@googlemail.com` addresses are routed
to Google OAuth automatically at the discovery step. Without them, users see an error
message asking them to configure OAuth.

### Other providers via PACC

For mail providers that publish a PACC configuration
(`https://ua-auto-config.{domain}/.well-known/user-agent-configuration.json`)
with an `authentication.oauth-public.issuer` field, the proxy will fetch RFC 8414
metadata from the issuer and initiate an OAuth2 + PKCE flow if client credentials
are configured.

Per-domain credentials are read from environment variables using the pattern:

```
OAUTH_EXAMPLE_COM_CLIENT_ID=...
OAUTH_EXAMPLE_COM_CLIENT_SECRET=...
```

where the domain is uppercased with non-alphanumeric characters replaced by `_`.
For example, `fastmail.com` → `OAUTH_FASTMAIL_COM_CLIENT_ID`.

Register `https://YOUR_DOMAIN/cb/oauth` as the redirect URI with each provider.

### Discovery order

For a given email address:

1. **Hardcoded**: `@gmail.com` / `@googlemail.com` → Google OAuth
2. **PACC**: `https://ua-auto-config.{domain}/.well-known/user-agent-configuration.json`
   - If `protocols.jmap.url` present → JMAP passthrough signup
   - If `authentication.oauth-public.issuer` present → RFC 8414 OAuth metadata → OAuth flow
   - Otherwise → pre-fill IMAP/SMTP settings from `protocols` block
3. **Mozilla autoconfig**: `https://autoconfig.{domain}/mail/config-v1.1.xml`
   - Pre-fills IMAP/SMTP settings
4. **Fallback**: password form with no pre-fill (DNS SRV lookup runs in the background worker)

## Credential Encryption

IMAP/SMTP passwords and OAuth refresh tokens are stored in per-account SQLite files.
`JMAP::CredentialStore` provides pluggable encryption for these fields.

### Backends

| Backend | When used | Ciphertext prefix |
|---------|-----------|-------------------|
| Plaintext | No env vars set (warns at startup) | _(none)_ |
| AES-256-GCM | `JMAP_SECRET_KEY` set | `enc1:` |
| OpenBao Transit | `JMAP_OPENBAO_ADDR` set | `vault:v1:` |

Decryption auto-detects the prefix, so you can migrate between backends without
re-encrypting all credentials at once — the old format is still readable while the
active backend re-encrypts on next write.

### AES-256-GCM (recommended for single-server deployments)

Generate a key:
```bash
openssl rand -hex 32
```

Set it in your environment (Docker, `.env`, etc.):
```
JMAP_SECRET_KEY=<64 hex chars from above>
```

Keep it **off the data volume** — if an attacker gets the SQLite files but not the key,
credentials are protected. Losing the key means losing access to all accounts.

### OpenBao Transit (recommended for production / multi-server)

Keys never leave OpenBao; the proxy only ever sees ciphertexts.

```bash
# Start OpenBao in dev mode (for testing — use proper storage in production)
docker run -d --name openbao \
  -e VAULT_DEV_ROOT_TOKEN_ID=mytoken \
  -p 8200:8200 quay.io/openbao/openbao:latest

# Enable transit and create the key
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=mytoken
bao secrets enable transit
bao write transit/keys/jmap-credentials type=aes256-gcm96
```

For the JMAP proxy, set one of:

```
# Option A: static token (simpler)
JMAP_OPENBAO_ADDR=http://openbao:8200
JMAP_OPENBAO_TOKEN=mytoken

# Option B: AppRole (recommended — avoids long-lived root tokens)
JMAP_OPENBAO_ADDR=http://openbao:8200
JMAP_OPENBAO_ROLE_ID=<role-id>
JMAP_OPENBAO_SECRET_ID=<secret-id>
```

Optional:
```
JMAP_OPENBAO_MOUNT=transit          # default
JMAP_OPENBAO_KEY=jmap-credentials   # default
```

### Migrating from plaintext to AES-256-GCM

1. Set `JMAP_SECRET_KEY` and restart the proxy
2. Credentials are re-encrypted the next time each account syncs (on `setuser` call)
3. To force immediate re-encryption of all accounts, trigger a settings update via the
   management API or accounts page

### Migrating from AES-256-GCM to OpenBao

1. Keep `JMAP_SECRET_KEY` set (needed to decrypt old `enc1:` values)
2. Set `JMAP_OPENBAO_ADDR` and restart — new writes use OpenBao, old reads still work
3. Once all accounts have been touched and re-encrypted, `JMAP_SECRET_KEY` can be removed

## TLS Termination

The proxy speaks plain HTTP. Put a reverse proxy in front for TLS.

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
        client_max_body_size 50m;  # for uploads
    }
}
```

### Caddy
```
jmap.example.com {
    reverse_proxy 127.0.0.1:9000
}
```
Caddy handles TLS certificates automatically via Let's Encrypt.
