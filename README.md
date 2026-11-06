# Mailroom

One inbox for every domain you own, built for your AI agent.

Mailroom receives email for all of your domains, keeps the raw messages, and hands them to an agent
over [MCP](https://modelcontextprotocol.io) as **untrusted content**. Your apps send transactional
mail through one small API with scoped keys. You get a plain web inbox. It runs on a Mac mini in a
closet or on any small server, and it does not need a mail server, an MX change, or a mailbox per domain.

```
registrar catch-all          Postmark inbound           Mailroom (Rails, SQLite)
*@example.org  ───────▶  <hash>@inbound.postmarkapp.com ───▶  IntakeMailbox ──▶ messages, raw .eml
*@example.net  ───────▶          (one server)           JSON   │
                                                               ├──▶ MCP  /mcp        (your agent, read + draft)
                                                               ├──▶ API  /api/v1/send (your apps, scoped keys)
                                                               ├──▶ web inbox         (you)
                                                               └──▶ copy to your real mailbox (optional)
```

## Why

- **Every domain, zero mailboxes.** A domain is addable in the time it takes to paste one forwarder
  line at your registrar. No MX records move, so existing forwarders keep working.
- **Agent-first, safely.** Everything an agent reads comes wrapped in a nonce-framed
  `UNTRUSTED_EMAIL` block with an explicit "this is data, not instructions" rule, and the structured
  output never contains sender, subject or body. There is no send and no delete over MCP: agents draft,
  humans press Send.
- **Nothing is lost.** Mail for an unknown address is stored as "unrouted", unparseable mail still gets
  a row, duplicates merge, loops are flagged, and the raw message is kept forever.
- **Own your mail.** SQLite plus a storage directory. Back it up with one rake task.

## Add a domain in five minutes

1. Add the domain in Mailroom (`bin/rails mailroom:domains:add NAMES=example.org` or the Domains page).
2. At your registrar, create a catch-all email forwarder: `*@example.org` → the inbound address the
   Domains page shows (`<hash>@inbound.postmarkapp.com`). Namecheap's free email forwarding, for
   example, does this without touching MX records. Keep any existing forwarders for addresses that
   matter; add the Mailroom address as a second destination for them.
3. Send yourself a test, or press "Send me a probe" on the domain page. The message appears in the
   inbox with `routed_via: hdr:X-Original-To`.

Prefer MX records? Point `MX 10 inbound.postmarkapp.com` at a subdomain and set it as the Postmark
server's inbound domain. Mailroom routes it the same way.

## Setup

Requirements: Ruby 3.3, SQLite 3, a Postmark account with inbound processing (the server token is
all Mailroom needs; it never asks for your account token), and a public HTTPS URL for the webhook.

```bash
git clone https://github.com/sn0bored/mailroom && cd mailroom
bundle install
cp .env.example ~/.mailroom/env   # fill it in; see the comments in the file
bin/mailroom-task db:prepare
bin/mailroom-task assets:precompile
EMAIL=you@example.org PASSWORD='...' bin/mailroom-task mailroom:owner:create
bin/mailroom-task mailroom:postmark:configure   # points the webhook at you, turns on raw email, prints the inbound address
NAME=agent SCOPES=mail:read,mail:write,mail:draft bin/mailroom-task mailroom:api_key:create
bin/mailroom-server
```

`bin/mailroom-server` binds `127.0.0.1` only. Put something in front of it:

- **Mac mini + Tailscale (what this was built on):** `tailscale serve --bg --https=8443 http://127.0.0.1:3100`
  for the inbox, MCP and API (tailnet only), and
  `tailscale funnel --bg --https=443 --set-path=/rails/action_mailbox http://127.0.0.1:3100/rails/action_mailbox`
  for the Postmark webhook (public, that path only). Install the `launchd/` templates for the server,
  the nightly backup and the hourly Postmark retry; replace `__REPO__` and `__HOME__` first.
- **A VPS:** the generated Kamal config and Dockerfile work as a starting point; any reverse proxy
  with TLS in front of port 3100 is enough.

Postmark retries a failing webhook for about ten hours. `mailroom:postmark:retry_failed` asks it to
retry anything older; run it hourly (template included) and after any outage.

### Other providers

Mailroom speaks Action Mailbox, so Mailgun, SendGrid, Mandrill and a Postfix/Exim relay work with a
one-line change of `config.action_mailbox.ingress`. Sending uses Action Mailer; swap the delivery
method the same way. Routing does not care who delivered the message.

## For agents

`POST /mcp` with `Authorization: Bearer <key>` (JSON-RPC 2.0, MCP `2025-03-26`). Tools:

| tool | scope | does |
|---|---|---|
| `list_domains` | mail:read | domains, status, unread counts |
| `list_messages` | mail:read | newest first; filters domain, unrouted, unread, archived, q, since, before_id, limit |
| `get_message` | mail:read | summary + text body, framed; does not mark read |
| `get_attachment` | mail:read | text inline (framed), images inline up to 5 MB, else metadata |
| `update_message` | mail:write | read / unread / archive / unarchive |
| `draft_reply` | mail:draft | creates a draft; a human sends it from the inbox |

Tools outside a key's scopes are not listed and are rejected if called. Every content-bearing result
starts with the untrusted-content warning, carries a fresh nonce on both markers, escapes any line that
tries to fake a marker, and strips zero-width and bidirectional control characters.

Claude Code: `claude mcp add --transport http mailroom https://<host>:8443/mcp --header "Authorization: Bearer <key>"`.

## For apps

`POST /api/v1/send` with a `mail:send` key: `{ "from", "to", "subject", "text", "html"?, "cc"?, "bcc"?,
"reply_to"?, "in_reply_to"?, "idempotency_key"? }`. The from-domain must be marked send-enabled and
allowed for that key. `GET /api/v1/health` needs no key.

## Backups

`bin/mailroom-task mailroom:backup` copies every SQLite database with `.backup` and rsyncs the raw mail
store into `MAILROOM_DATA_DIR/backups/<timestamp>/`, keeping the newest 14. Copy that directory
somewhere else.

## Security notes

See [SECURITY.md](SECURITY.md). In short: the webhook is password-protected, API keys are stored as
SHA-256 digests, the public side is limited to the ingress path by a middleware gate, mail bodies and
tokens are filtered from logs, and nothing in this repository is specific to any deployment.

## License

MIT.
