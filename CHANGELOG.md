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

### Review
- Results are marked reviewed automatically when you reply in that session or deliberately view the full result in the
  island for a few seconds (opt-out in Settings); manual **Open** / **Mark reviewed** remain.

### Subagents and questions
- Per-session subagent stat ("2 running · 1 done") on every session in both views, alongside the global header count.
- Fixed sessions showing **Idle** while background subagents were still working: the main turn's `Stop` no longer
  force-closes subagents, the session stays Working until the last one stops, and the "finished" notification waits.
- Subagent tree: running-first ordering, per-session expand/collapse, current tool, tool-call counts, last result,
  and a running-subagent count in the headers. Silent subagents are settled after 15 minutes.
- Claude's questions (`AskUserQuestion`) render as questions with their choices and friendlier actions and notifications.

### Rendering
- Claude's replies render inline markdown (bold, code, links) with block syntax flattened; subagent hand-backs, task
  notifications and system reminders no longer replace your real prompt; worktree and scratch-workspace sessions get
  readable names; a detached `HEAD` is not shown as a branch.
- Narrower island (320 / 350 / 420 pt presets, 320 pt compact view); clicking a compact row opens it in the detailed view.
- The last reported plan limits are remembered across restarts.

### Reliability
- Per-field lenient hook payload decoding (the status line's object-valued `model` no longer drops the event).
- Hook forwarder deadlines and payload truncation; ordered, deadline-bounded IPC; safe reply-handle lifecycle.
- Held approvals are released only by events that settle them; answering a gone hook is a no-op.
- Installer guards: symlinks, permissions, unexpected shapes, no-op writes, concurrent-edit detection, exact-name matching.
- Usage de-duplicated globally across transcripts; quota windows clamp, normalize timestamps, and expire locally.
