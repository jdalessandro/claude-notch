# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - Unreleased

### Added
- Dynamic-Island-style overlay for the MacBook display cutout (floating or attached), with a collapsed
  tile + waveform and an expanded view that groups sessions by what needs you.
- Per-session prompt, current tool, subagent tree, context meter, and the result of finished turns.
- Compact and detailed expanded views, switchable from the island header; the last-used view is remembered.
- Approve or deny tool permissions from the island.
- Plan-limit usage in the style of Claude Desktop (5-hour, weekly, per-model weekly) as percentage bars, with a
  Limits | Tokens toggle for token totals (last 5 hours, today, 7 days). Dollar cost is hidden on subscription plans.
- Settings window: island style and width, hover behavior, content, notifications, integration, diagnostics.
- `claude-notch-hook` forwarder with `--install`/`--uninstall`/`--statusline`, merging safely into
  `~/.claude/settings.json`.

### Reliability
- Per-field lenient hook payload decoding (the status line's object-valued `model` no longer drops the event).
- Hook forwarder deadlines and payload truncation; ordered, deadline-bounded IPC; safe reply-handle lifecycle.
- Held approvals are released only by events that settle them; answering a gone hook is a no-op.
- Installer guards: symlinks, permissions, unexpected shapes, no-op writes, concurrent-edit detection, exact-name matching.
- Usage de-duplicated globally across transcripts; quota windows clamp, normalize timestamps, and expire locally.
