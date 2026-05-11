# JMAP Proxy

A proxy server that bridges IMAP/CalDAV/CardDAV mail backends to the
[JMAP](https://jmap.io/) protocol (RFC 8620/8621, JMAP Calendars, JMAP Contacts).
It also supports direct JMAP-to-JMAP passthrough for backends that already speak JMAP.

Live demo: **[proxy.jmap.io](https://proxy.jmap.io)**

## What it does

- Syncs email from any IMAP server and exposes it over JMAP (RFC 8621)
- Syncs calendars and contacts via CalDAV/CardDAV (JSCalendar, JSContact)
- Passes JMAP requests through unchanged to native JMAP backends (Cyrus, Fastmail, etc.)
- Handles OAuth2 sign-up for Gmail and Fastmail
- Multi-account: one proxy instance can serve many users, each with their own backend
- Cross-account copy (`Blob/copy`, `Email/copy`, `CalendarEvent/copy`, `ContactCard/copy`)
- Push notifications via Server-Sent Events (RFC 8620 §7.3)
- Prometheus metrics, credential encryption (AES-256-GCM or OpenBao Transit)

## Quick start

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

Then open `http://localhost:8080` to add accounts via the management dashboard.

## Documentation

| Document | Description |
|---|---|
| [SETUP.md](SETUP.md) | Deployment guide: Docker, TLS, env vars, OAuth2, encryption |
| [API.md](API.md) | Management API reference (accounts, health, metrics) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Internal architecture: process model, data flow, worker protocol |
| [ROADMAP.md](ROADMAP.md) | Feature status and spec compliance notes |

## Requirements

- Perl 5.20+ (source) or Docker (recommended)
- IMAP server with CONDSTORE support (RFC 4551/7162) for email sync
- CalDAV/CardDAV server for calendar and contacts sync

## JMAP compliance

132/132 JMAP TestSuite tests passing against Cyrus IMAP, covering:
RFC 8620 core, RFC 8621 mail, JMAP Calendars, JMAP Contacts (RFC 9610),
Quota (RFC 9425), Principal, MDN (RFC 9007), and EmailSubmission.

## License

See [LICENSE](LICENSE).
