# Security

## Trust model

Notchbot is a local, single-user tool. It has no network code and sends nothing off the machine.

- **Hooks** run as you whenever Claude Code fires an event. `notchbot-hook` only reads the event JSON from stdin
  and forwards it to the app over a Unix socket. If the app is not running it exits silently, and it never blocks or
  fails a Claude session.
- **Bounded by design**: every forwarder socket operation has a deadline, free-text fields are truncated before sending, and the
  server reads each connection under a short total deadline, so a stalled or hostile local client cannot hang a session.
- **Socket**: `~/Library/Application Support/Notchbot/notch.sock`, mode `0600` inside a `0700` directory, so only
  your user can connect. A process running as you could inject fake status events, but it cannot approve a permission:
  decisions only flow back to the specific hook process that asked.
- **Approvals**: with *Approve permissions from the island* on, a `PermissionRequest` hook holds Claude's prompt until
  you click Allow or Deny (up to Claude Code's 10-minute hook timeout). Turn the setting off for observe-only mode.
- **Settings changes**: the installer merges into `~/.claude/settings.json`, keeps a one-time `.notchbot.bak`,
  never replaces a status line you already have, and `--uninstall` removes only its own entries.
- **Diagnostics log**: off by default. When enabled it records raw hook events, which include prompt text and tool
  inputs, to `~/Library/Application Support/Notchbot/events.jsonl`. Treat it as sensitive.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** (Security ▸ Report a vulnerability) rather than a public issue.
