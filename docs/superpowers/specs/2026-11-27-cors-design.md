# CORS for browser JMAP clients — design

Date: 2026-11-27
Status: implemented, against master 05b71df (`JMAP/CORS.pm`, `t/cors-origins.t`,
`t/cors.t`). Where the implementation differs from the proposal, the section
says so under "As built".

## Problem

A webmail served from another origin (for example Bulwark at
`https://webmail.example.com`, signing in through `JMAP_OIDC_CLIENTS`) talks
to the proxy's JMAP API from the browser. Every such call sends
`Authorization` and `Content-Type: application/json`, so the browser first
sends a CORS preflight (`OPTIONS`). Today the proxy fails it in two ways:

- `OPTIONS` is answered `501 not implemented`. `allowed_methods` leaves it out
  (`bin/jmap-proxy.pl:4821`), and AnyEvent::HTTPD refuses the method before
  any route runs.
- No response carries `Access-Control-Allow-Origin`.

As a result, the sign-in itself works: `/oauth/authorize` is a top-level
navigation, and the webmail's server makes the token exchange. But the
browser then blocks the first `/session` fetch and every call after it.

Observed behind a TLS-terminating reverse proxy that adds no headers:

```
$ curl -si -X OPTIONS -H 'Origin: https://webmail.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: authorization, content-type' \
    https://jmap.example.com/jmap/
HTTP/1.1 501 not implemented

$ curl -si -H 'Origin: https://webmail.example.com' \
    https://jmap.example.com/.well-known/openid-configuration | grep -i access-control
(nothing)
```

CORS existed before, but never in `bin/jmap-proxy.pl`:

- `bin/server.pl` set `Access-Control-Allow-Origin: *`. It was removed with
  the pre-jmap-proxy servers in 0572c56.
- `nginx.conf` answered `OPTIONS` for `/jmap/`, `/upload/` and `/events/`. It
  was removed as a stale config in 4beba82.
- proxy.jmap.io does CORS in its Caddy config. That is the `[x] CORS headers
  for cross-origin webmail clients` in `ROADMAP.md`.

The Caddy and nginx examples in `SETUP.md` have no CORS. An operator who
follows `SETUP.md` therefore gets a proxy that no cross-origin webmail can
use, even though `JMAP_OIDC_CLIENTS` exists for "a webmail doing SSO".

## Goal

The proxy answers CORS itself, for the origins the operator allows, with no
reverse-proxy configuration. Same-origin clients, native apps and non-browser
clients see no change.

## Decisions

### 1. Which origins: `JMAP_CORS_ORIGINS`, defaulting to the OIDC clients

- `JMAP_CORS_ORIGINS` is a space- or comma-separated list of origins, each
  `scheme://host[:port]` with no path, spelled the way a browser sends
  `Origin`: lower case, no default port. `*` allows any origin.
- If it is unset or empty, the allowed origins are the origins of the `http(s)`
  redirect URIs in `JMAP_OIDC_CLIENTS`. A webmail registered for SSO then needs
  no second setting. Redirect URIs with other schemes (such as
  `bulwarkmobile://auth/callback`) belong to native apps and are skipped.
- Empty is treated like unset because Compose files commonly pass
  `${VAR:-}`. An empty value must not quietly turn the derived list off.
- With neither variable set, the list is empty and CORS stays off, as today.
- An entry with a path, or one that is not an origin, gets a startup `warn`
  and is ignored. The server still starts. This is the same way a malformed
  `JMAP_OIDC_CLIENTS` is handled.
- At startup, log the effective list next to "Base URL", for example:
  `CORS origins: https://webmail.example.com (from JMAP_OIDC_CLIENTS)`.

As built: entries are normalised to the browser's spelling instead of being
refused for it (scheme and host lower-cased, a default port and a lone
trailing `/` dropped). The incoming `Origin` is still compared exactly. An
explicit entry may use any scheme (an app webview's `tauri://localhost`).
`null` is never an origin. A non-empty `JMAP_CORS_ORIGINS` replaces the
derived list even if none of its entries is valid.

Put the parsing and matching in a small pure module, `JMAP/CORS.pm`, like
`JMAP::Dispatch` and `JMAP::Collation`: no I/O and unit-tested. It takes the
two env values (the decoded OIDC client map) and answers, for a given
`Origin`, the `Access-Control-Allow-Origin` value or `undef`. Note that
`%OIDC_CLIENTS` (`bin/jmap-proxy.pl:4501`) is keyed by redirect URI per
client, so the origins can be read from it directly.

### 2. Never `Access-Control-Allow-Credentials`

Browser clients authenticate with the `Authorization` header (Bearer or
Basic). A cross-origin `fetch` sends that header without credentials mode.
Cookies are never needed, so:

- The `jmap_proxy` session cookie never rides on a CORS request, and
  `Access-Control-Allow-Credentials` is never sent.
- `_cross_site` (`bin/jmap-proxy.pl:3141`) keeps guarding the cookie session
  exactly as now. `_authenticate` (3294) tries Bearer, then the cookie, then
  Basic. A Bearer request never reaches the cross-site check, and a
  cross-origin `fetch` without `credentials: 'include'` sends no cookie, so a
  Basic request from an allowed origin does not reach it either.
- With `*`, the literal `*` is sent. Without credentials, that cannot expose
  anything a request without a token could not already see.

### 3. Preflight: answered in the parent, before routing

- Add `OPTIONS` to `allowed_methods` on the JMAP port (4821).
- A `request` callback (next to the stats one at 4823) answers every
  `OPTIONS` with `204` and calls `$httpd->stop_request`, so no route handler
  ever sees an `OPTIONS`. AnyEvent::HTTPD emits `request` before the
  path-prefix events, and `stop_request` ends the walk. Confirm this against
  the installed AnyEvent::HTTPD version.
- For an allowed `Origin`, the 204 carries:
  - `Access-Control-Allow-Origin: <origin>` (or `*`)
  - `Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH`
  - `Access-Control-Allow-Headers: <the request's Access-Control-Request-Headers>`.
    Echoing is safe here because only allowed origins get it.
  - `Access-Control-Max-Age: 7200` (Chromium's cap)
  - `Vary: Origin, Access-Control-Request-Headers`
- For any other origin, or with no `Origin` at all, the 204 carries only
  `Allow: GET, HEAD, POST, PUT, PATCH, OPTIONS`, and the browser then refuses
  the call.
- The parent must never block. This is header arithmetic only.

As built, checked against AnyEvent::HTTPD 0.93 (Debian trixie): the 501 comes
from `HTTPConnection::push_header_line`, which refuses a method outside
`allowed_methods` before the headers are read. `handle_app_req` emits
`request` first and returns when `req_stop` is set, so no path event runs.
The 204 carries no `Content-Length` (RFC 9110 S8.6). Setting it to `undef`
keeps AnyEvent::HTTPD from adding one, at the price of `Connection: close`
on that answer.

### 4. Actual responses: in the existing `respond` hook

The hook at 4785–4815 already adds default headers (`nosniff`,
`X-Frame-Options`, `Referrer-Policy`) to every array response. It also adds
`Access-Control-Allow-Origin` and `Vary: Origin` when the request's
`Origin` (`$self->headers->{origin}`) is allowed, unless the handler set the
header itself. Because every response goes through it, this covers:

- 2xx;
- 3xx: the `/.well-known/jmap` → `/session` redirect. A cross-origin `fetch`
  follows a redirect only if the redirect response carries the header. The
  hook already turns `{ redirect => ... }` into an array before adding headers.
- 4xx/5xx: a `401` must reach the client as a 401, not as an opaque CORS
  failure.
- The SSE stream: `do_eventsource` (4375) responds with an array whose body is
  a code ref.

`Access-Control-Expose-Headers` is out of scope. No JMAP client is known to
read a non-safelisted response header. Add it if one turns out to.

As built: once CORS is on, every answer on the JMAP port carries
`Vary: Origin`, including answers to requests without `Origin` or from another
origin. Otherwise a cache could hand an answer made for no origin to a CORS
request, or the reverse (Fetch Standard, "CORS protocol and HTTP caches").
The hook is installed on `AnyEvent::HTTPD::Request::respond`, so it runs for
the management port too. It decorates only requests whose server is the JMAP
port's (`refaddr` of `$req->{httpd}`).

### 5. Known gap: errors written by the connection

The 413 from the patched `push_header` (4772) and AnyEvent::HTTPD's own
errors are written through `HTTPConnection::error`, not
`Request::respond`, so they carry no CORS header. A browser reports them as a
network error rather than a 413. That is acceptable for this step. A
follow-up could pass the parsed request header (`$hdr`, which holds
`origin`) and add the header there.

### 6. Scope

- Only the JMAP port. The management port (5232) is unchanged.
- No per-path origin lists. Every path on the JMAP port behaves the same
  (`/session`, `/jmap`, `/upload`, `/raw`, `/eventsource`, `/filenode`,
  `/oauth/*`, `/.well-known/*`). A pure in-browser SPA doing PKCE would call
  `/oauth/token` and `/oauth/userinfo` itself, so they need it too.

## Docs

- `SETUP.md`, env table: add a `JMAP_CORS_ORIGINS` row after
  `JMAP_OIDC_CLIENTS`, with the default ("the origins of the http(s) redirect
  URIs in `JMAP_OIDC_CLIENTS`"), the list format and `*`.
- `SETUP.md`, TLS Termination: add one sentence. The proxy answers CORS
  itself, so the reverse proxy must pass `OPTIONS` through and must not add
  its own `Access-Control-*` headers, because duplicated headers fail the
  browser's check.
- `ROADMAP.md`: add "CORS in the proxy itself (`JMAP_CORS_ORIGINS`)" as done.
- `CLAUDE.md`, Code layout: add a one-line entry for `JMAP/CORS.pm`
  ("pure, `t/cors-origins.t`").

## Tests

### `t/cors-origins.t`: pure, no server

- Unset or empty `JMAP_CORS_ORIGINS` plus `JMAP_OIDC_CLIENTS` with
  `https://webmail.example.com/de/auth/callback`,
  `https://webmail.example.com/en/auth/callback` and
  `bulwarkmobile://auth/callback` gives exactly `https://webmail.example.com`.
- A comma- and space-separated list is parsed. An entry with a path or
  without a scheme is dropped with a warning.
- `*` matches any origin and yields `*`.
- Matching is exact: `https://webmail.example.com.evil.test`, `http://`
  instead of `https://`, and another port do not match.
- No variables set gives an empty list.

### `t/cors.t`: against a running stack, like `t/account-access.t`

Skipped unless `JMAP_PROXY_URL` is set. Start the stack with
`JMAP_CORS_ORIGINS=https://webmail.example` exported;
`restart-test-proxy.sh` passes its environment through to the proxy.

1. Preflight from the allowed origin to `/jmap`, `/session`,
   `/upload/<id>`, `/eventsource` and `/.well-known/jmap`: `204`, the
   origin echoed, `POST` in `Allow-Methods`, `authorization, content-type`
   echoed, no `Allow-Credentials`.
2. Preflight from another origin: `204` and no `Access-Control-Allow-Origin`.
3. Preflight without `Origin`: not `501`.
4. `GET /.well-known/jmap` with the allowed `Origin`: `301` with the header.
5. Unauthenticated `POST /jmap` with the allowed `Origin`: `401` with the
   header.
6. Authenticated `POST /jmap` (Basic, `any_account`) with the allowed
   `Origin`: `200`, the header and `Vary: Origin`. The same request from
   another origin gets no header.
7. Regression: a request without `Origin` gets no `Access-Control-*`
   header and the default headers as today. As built, it also gets
   `Vary: Origin` (see 4).
8. As built: the management port answers no CORS (`JMAP_MGMT_URL`).

As built, the 200 without an account is `GET /.well-known/openid-configuration`.
The authenticated call (6) logs in as `JMAP_TEST_LOGIN` (default
`user1@example.com`) and is skipped when that login fails.

## Manual check with a webmail

1. Configure `JMAP_OIDC_CLIENTS` with the webmail's redirect URIs and leave
   `JMAP_CORS_ORIGINS` unset.
2. Run the two `curl` commands from "Problem". The preflight is now `204`,
   with `Access-Control-Allow-Origin: https://webmail.example.com`.
3. Sign in from the webmail and confirm that the mailbox list loads, a
   message opens (`/raw`), an attachment uploads (`/upload`), and new mail
   arrives by push (`/eventsource`).
