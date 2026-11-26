# Research notes

How Claude Code can be observed from outside, and what was verified. Sources: Claude Code documentation (hooks, status
line, monitoring, sessions, desktop, Agent SDK) and inspection of a real `~/.claude` (Claude Code 2.1.x).

| Surface | Used | Notes |
|---|---|---|
| Hooks (`settings.json`) | yes, primary | Push events with `session_id`, `transcript_path`, `cwd`. `PermissionRequest` hooks can return allow/deny. Events from inside a subagent also carry `agent_id` / `agent_type`. |
| Transcripts (`~/.claude/projects/**.jsonl`) | yes, primary | `message.usage`, `requestId`, `isSidechain`, `entrypoint`, titles, and a `cost-state` record with the authoritative `totalCostUSD`. Written by the CLI **and** the desktop app (`entrypoint: "claude-desktop"`). The format is internal and may change. |
| Usage endpoint (`api.anthropic.com/api/oauth/usage`) | yes, primary for plan limits | What Claude Code's `/usage` calls, with Claude Code's OAuth token from the keychain. Works for desktop-only users too. Undocumented, so failures keep the last-known numbers. |
| Model catalog (`~/.claude/cache/model-catalog/*.json`) | yes | `runtime.max_input_tokens` per model: the context-window size without hardcoding it. |
| Status line | yes, optional | Exposes `rate_limits` (5-hour / weekly, subscribers) and the exact `context_window_size`, but only while a terminal session answers. Single-slot setting, so we never replace an existing one. |
| OpenTelemetry | no | Default export interval (60 s) is too slow for a live overlay. |
| Agent SDK | no | Spawns and controls its own sessions; cannot attach to an interactive CLI/desktop session. |

Verified behaviors: hooks fire for **desktop-app Code-tab sessions** and are picked up without restarting running
sessions; desktop sessions write transcripts to the same store; user-level hooks from other tools already exist in
`settings.json`, so installers must merge, never overwrite.

Decision schema for `PermissionRequest`:
`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny","message":"..."}}}`.
No output means "fall through to the normal prompt".

Unverified / may vary by version: exact `Notification` field names (the reducer also falls back to message text),
whether `rate_limits` includes per-model weekly windows for every plan (the parser is generic), and the usage
endpoint's response shape.
