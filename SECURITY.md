# Security

Mailroom handles mail from strangers and hands it to software that can act. The design assumes every
message is hostile until a human says otherwise.

## What is in place

- **Untrusted-content framing for agents.** Every MCP result that carries mail content starts with an
  explicit warning, wraps the content in `<<<UNTRUSTED_EMAIL nonce=… >>>` markers with a nonce that is
  new on every call, escapes any content line that starts with `<<<`, and strips zero-width and
  bidirectional control characters. Structured output never includes sender, subject or body.
- **No send, no delete over MCP.** Agents can draft replies; only a signed-in owner can send one.
  Apps send through the REST API with a `mail:send` key restricted to listed domains.
- **Scoped, hashed API keys.** Keys are `mr_<prefix>_<secret>`, shown once, stored as SHA-256 digests,
  revocable. Tools outside a key's scopes are invisible in `tools/list` and rejected in `tools/call`.
- **Ingress authentication.** The Postmark webhook requires HTTP basic auth
  (`actionmailbox:$RAILS_INBOUND_EMAIL_PASSWORD`); the app refuses to boot in production without it.
- **Public-side gate.** Mailroom runs two loopback listeners: an internal one for the inbox, MCP and API,
  and a public one for the webhook. A middleware lets a request through to the whole app only when its
  connection was accepted on a loopback address at the internal port. No header can grant that; a
  request Tailscale Funnel forwarded, or whose nearest `X-Forwarded-For` hop is a public address, gets
  the public rules even there. The public rules allow `GET /up`, and `POST` to the Postmark webhook path
  with the ingress password, which the middleware checks before Rails parses or logs the body.
  Everything else is a 404. `Client-IP` and `Forwarded` headers are dropped, so no client chooses the
  address Rails logs and rate-limits by. Every other route needs a session or a key as well.
- **Boot checks.** Production refuses to start unless Puma listens on exactly the two loopback ports
  (`rails server -p`, `PORT` or Thruster would replace them with one listener on every interface),
  without a separate public port, or with an ingress password under 32 characters. Request bodies over
  100 MB get a 413 from Puma before the app runs.
- **Nothing rendered from mail.** The web inbox shows text bodies only, escaped. Attachments download
  through an authenticated controller with `Content-Disposition: attachment`; blob URLs are never exposed.
  The owner UI sends a strict Content-Security-Policy (`default-src 'self'`, nonce-only inline code,
  `object-src 'none'`, `frame-ancestors 'none'`).
- **Forward copies name their sender.** A forward copy comes from the owner's own domain, so its HTML
  is sanitized against an allowlist (no script, forms, frames, embeds or remote images) and starts
  with a banner giving the original From, To, Date and sender check. A failed check tags the subject
  `[unverified sender]`. The check comes from the registrar forwarder's `Authentication-Results` when
  its authserv-id is listed in `MAILROOM_TRUSTED_AUTHSERV_IDS`; only the topmost header with a listed
  id counts. Otherwise it comes from Postmark's SPF and DKIM results, which cannot vouch for forwarded
  mail and leave it "unknown" (see "Sender checks" in the README).
- **Loop marker.** Forward copies and probes carry `X-Mailroom-Loop`, an HMAC of their own Message-ID,
  so a marker copied into other mail does not suppress its forward copy. Replies carry no marker.
- **No hostname in Message-IDs.** Every message Mailroom sends has a Message-ID of the form
  `<uuid@From domain>`, never the Mail gem's default, which ends in the machine's hostname.
- **Logs.** Raw payloads, tokens, passwords, and mail bodies, subjects and addresses are filtered from
  the Rails log. The webhook
  URL, which embeds the ingress password, is never printed.
- **Throttling.** Logins, agent and API traffic, and sends are rate limited.
- **Data at rest.** SQLite and a storage directory you own. Back them up; encrypt the disk.

## What is not in place

- Mail is not scanned for malware. Attachments are stored as received.
- Spam scoring comes from the provider. The ingress copies Postmark's score into
  `X-Mailroom-Spam-Score` at the top of the stored message, and a sender's own `X-Spam-Score` never
  overrides it. Mailroom only uses the score to decide whether to forward a copy; nothing is dropped.
- There is one owner account and no roles.

## Large uploads and temporary disk space

Puma reads request bodies before the ingress gate or authentication runs. Large bodies are spooled
to temporary files, including unauthenticated uploads. The 100 MiB request limit bounds one upload,
not total disk use: five concurrent 99 MB uploads held about 472 MiB of temporary files for roughly
30 seconds in testing. Enough concurrent uploads can exhaust temporary disk space and disrupt mail.
Chunked uploads can consume space before reaching the size limit, too.

Puma now uses a 10-second `first_data_timeout` and a 5-second `persistent_timeout`.
In Puma 8.0.2, the former also applies while a body is incomplete; each incomplete read resets it.
The latter applies when waiting for another request on a keep-alive connection, including an
incomplete next request, until the reactor resets it to `first_data_timeout`.
These settings shorten stalled uploads, but neither is a total upload deadline or minimum data rate.
A client that keeps trickling data can retain its file. See `lib/puma/server.rb:321-328,491-501,515-535`
and cleanup in `lib/puma/client.rb:194-206,350-352` in the Puma 8.0.2 source.

The reference deployment uses Tailscale Funnel, which does not provide configurable request-body
or per-client connection limits. Puma has no per-listener concurrent-connection cap. The timeouts
therefore leave a disk-exhaustion risk on that deployment.

On a VPS, put a reverse proxy in front of the public listener and configure both a body size limit
and per-IP connection limits. For nginx, add the zone in the `http` context and the other directives
to the existing public TLS `server` block (complete TLS setup is omitted):

```nginx
# http context
limit_conn_zone $binary_remote_addr zone=mailroom_uploads:10m;

# public server context
client_max_body_size 100m;
client_body_timeout 10s;
limit_conn mailroom_uploads 2;

location / {
    proxy_pass http://127.0.0.1:3101;
}
```

Use the configured public port, never the internal listener. Tune concurrency for legitimate
webhook traffic. nginx counts connections after reading request headers and counts concurrent
HTTP/2 and HTTP/3 requests separately. Use the actual client IP; only accept forwarded IP headers
from a trusted upstream. Proxy buffering also uses temporary disk, and distributed clients can
exceed a per-IP budget, so monitor disk space and consider an aggregate proxy limit as well.
See nginx's `client_max_body_size`, `client_body_timeout`, and `limit_conn` documentation.

## Reporting

Email the maintainer address listed on the repository profile. If private security advisories are
enabled on the repository (Settings → Security), you may open one there instead. Please do not open
public issues for security problems.
