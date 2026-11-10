# Contributing to Mailroom

Thanks for your interest in Mailroom. It is a small, focused project, and contributions that keep it
that way are welcome: bug fixes, documentation, provider adapters, and tests.

## Before you start

- Open an issue first for anything beyond a small fix, so we can agree on the approach before you write
  code. For security problems, do **not** open a public issue — see [SECURITY.md](SECURITY.md).
- By contributing you agree your work is licensed under the project's [MIT License](LICENSE).

## Development setup

Requirements: Ruby (see `.ruby-version`), SQLite 3, and Bundler.

```bash
git clone https://github.com/sn0bored/mailroom && cd mailroom
bundle install
cp .env.example .env            # fill in only what a test run needs
bin/rails db:prepare
bin/rails test                  # the suite runs without a Postmark account
```

The test suite is self-contained: it does not call Postmark, send real mail, or need a public URL.
Nothing in the repository is specific to any one deployment, and it should stay that way — use
placeholders (`example.org`, `/path/to/mailroom`, `YOUR_TOKEN`) in docs and fixtures, never a real
host, path, address, or key.

## Making a change

1. Branch off `main`.
2. Keep commits small and logical, with a clear message describing the *why*.
3. Add or update tests for behavior you change. Untrusted-content framing, scope enforcement, and
   routing are the sensitive areas — cover them.
4. Run the checks before you push:

   ```bash
   bin/rails test
   bin/rubocop
   bin/brakeman        # if you touched anything security-adjacent
   ```

5. Open a pull request against `main`. Describe what changed and how you tested it. CI
   (`.github/workflows/ci.yml`) runs RuboCop, Brakeman, and the test suite on every PR.

## Style

- Follow the existing RuboCop config (`.rubocop.yml`); match the surrounding code.
- Prefer clear, boring Rails over cleverness. This is infrastructure people leave running unattended.
- Keep the agent (MCP) surface conservative: no new send-or-delete capability over MCP, and every
  content-bearing result stays inside the untrusted-content framing.

## What tends to get merged

- Bug fixes with a regression test.
- New inbound/outbound provider adapters that reuse the Action Mailbox / Action Mailer seams.
- Documentation that helps a stranger run Mailroom on their own hardware.
- Reliability improvements (retries, backups, loop detection).

## What tends not to

- Features that widen what an agent can do without a human in the loop.
- Anything that hard-codes a specific host, path, domain, or deployment.
- Large dependencies for small gains.
