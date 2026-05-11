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
  -p 9000:9000 \
  -p 127.0.0.1:8080:8080 \
  -v /data/jmap-proxy:/data \
  -e BASEURL=https://jmap.example.com \
  ghcr.io/jmapio/jmap-proxy:latest
```

- **Port 9000**: JMAP endpoint (public — put behind a TLS reverse proxy)
- **Port 8080**: Management API (keep localhost-only)
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
| `JMAP_SYNC_INTERVAL` | `30` | Seconds between background IMAP/CalDAV/CardDAV sync polls. |
| `JMAP_DEBUG` | _(unset)_ | Set to any value to log full JMAP request/response bodies to stderr. |
| `JMAP_SECRET_KEY` | _(unset)_ | 64 hex chars (256-bit AES key) for credential encryption. Recommended for production. |
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

---

## OAuth2 Setup

### Gmail

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable the **Gmail API** and **People API**.
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

IMAP/SMTP passwords and OAuth tokens are stored in SQLite. Without encryption
they are stored in plaintext — acceptable for personal use but not for
multi-user deployments.

### AES-256-GCM (single-server)

```bash
# Generate a key
openssl rand -hex 32
```

```
JMAP_SECRET_KEY=<64-hex-chars>
```

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
accounts have been re-encrypted — old `enc1:` values are still readable.

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
this enabled in production — it logs credentials in OAuth responses.

**SSE push not working behind nginx**  
Add `proxy_buffering off` and `proxy_read_timeout 3600` to the nginx location
block, and ensure `X-Accel-Buffering: no` is passed through.
