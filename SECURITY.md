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
- **Public-side gate.** A middleware allows only the Action Mailbox ingress paths and `/up` for requests
  that did not arrive through the private side (Tailscale identity headers, the tailnet port, a local
  host, or a forwarded tailnet client address). Every other route needs a session or a key as well.
- **Nothing rendered from mail.** The web inbox shows text bodies only, escaped. Attachments download
  through an authenticated controller with `Content-Disposition: attachment`; blob URLs are never exposed.
- **Logs.** Raw payloads, tokens, passwords and mail bodies are filtered from the Rails log. The webhook
  URL, which embeds the ingress password, is never printed.
- **Throttling.** Logins, agent and API traffic, and sends are rate limited.
- **Data at rest.** SQLite and a storage directory you own. Back them up; encrypt the disk.

## What is not in place

- Mail is not scanned for malware. Attachments are stored as received.
- Spam scoring comes from the provider (`X-Spam-Score`). Mailroom only uses it to decide whether to
  forward a copy; nothing is dropped.
- There is one owner account and no roles.

## Reporting

Email the maintainer address listed on the repository profile. If private security advisories are
enabled on the repository (Settings → Security), you may open one there instead. Please do not open
public issues for security problems.
