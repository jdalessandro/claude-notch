# Security

## Trust model

Claude Notch is a local, single-user tool. It makes exactly one kind of network request, described below; nothing
else leaves the machine.

- **Plan limits (Pro/Max only)**: every ~5 minutes, and when you tap the refresh icon on the island, the app asks
  `https://api.anthropic.com/api/oauth/usage` for your 5-hour and weekly limit percentages. This is the request
  Claude Code's `/usage` makes; it is not a documented API, so failures just keep the last-known numbers.
  - It authenticates with **Claude Code's own OAuth login**, read from the `Claude Code-credentials` keychain item
    (macOS asks you once to allow this). The token is sent only to Anthropic and is never logged.
  - When that login has expired, the app **renews it with the refresh token and writes the new credentials back to
    the same keychain item**. Renewal rotates the refresh token, so if Claude Code renews at the same moment one of
    them can end up with a stale token and Claude Code may ask you to sign in again.
  - Nothing is sent on API (pay-as-you-go) billing, where there are no plan limits.

- **Hooks** run as you whenever Claude Code fires an event. `claude-notch-hook` only reads the event JSON from stdin
  and forwards it to the app over a Unix socket. If the app is not running it exits silently, and it never blocks or
  fails a Claude session.
- **Bounded by design**: every forwarder socket operation has a deadline, free-text fields are truncated before sending, and the
  server reads each connection under a short total deadline, so a stalled or hostile local client cannot hang a session.
- **Socket**: `~/Library/Application Support/ClaudeNotch/notch.sock`, mode `0600` inside a `0700` directory, so only
  your user can connect. A process running as you could inject fake status events, but it cannot approve a permission:
  decisions only flow back to the specific hook process that asked.
- **Approvals**: with *Approve permissions from the island* on, a `PermissionRequest` hook holds Claude's prompt until
  you click Allow or Deny (up to Claude Code's 10-minute hook timeout). Turn the setting off for observe-only mode.
- **Settings changes**: the installer merges into `~/.claude/settings.json`, keeps a one-time `.claude-notch.bak`,
  never replaces a status line you already have, and `--uninstall` removes only its own entries.
- **Diagnostics log**: off by default. When enabled it records raw hook events, which include prompt text and tool
  inputs, to `~/Library/Application Support/ClaudeNotch/events.jsonl`. Treat it as sensitive.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** (Security ▸ Report a vulnerability) rather than a public issue.
