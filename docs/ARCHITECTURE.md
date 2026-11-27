# Architecture

```
claude (CLI / desktop)                              Notchbot.app
   | hook event (stdin JSON)                          |- NotchServer     Unix socket (0600), ordered delivery
   v                                                  |- SessionStore    pure reducer: events -> sessions
notchbot-hook --- notch.sock --------------->     |- TranscriptTailer  per-session usage / title / cost
   ^  PermissionRequest: blocks until answered        |- UsageAggregator   quota windows from all transcripts
   '------------- Allow / Deny <---------------       `- ActivityHost      Live Activity (widget extension draws it)
claude status line --- notchbot-hook --statusline -->  QuotaState (rate limits, exact context window)
```

## Modules

- **NotchbotCore** has no UI dependencies. `SessionStore.apply(_:)` is a pure function of (state, event), so the whole
  state machine is unit-tested without a display. IPC, the settings-file installer, transcript parsing and
  preferences are also here.
- **notchbot-hook** reads one JSON event on stdin, sends it, and exits 0. Only `PermissionRequest` (with
  `--interactive`) waits for a reply, which it prints in Claude Code's decision schema.
- **Notchbot** (`App/`, `Shared/`, `Widget/`, built by the generated Xcode project) owns presentation. `AppModel`
  (`@Observable`) is the single source of truth; the Live Activity and the *Sessions* window both render from it.

## Event model

| Hook event | Effect |
|---|---|
| `UserPromptSubmit` | working; records the prompt; clears the previous turn's subagents |
| `PreToolUse` / `PostToolUse` | current tool; a `Task`/`Agent` call queues a subagent description |
| `SubagentStart` / `SubagentStop` | subagent lifecycle. Events carrying `agent_id` update that subagent only, never the parent's status |
| `PermissionRequest` | needs-permission; pending request with Allow/Deny when the hook is waiting |
| `Notification` | `permission_prompt` / `idle_prompt` / `elicitation_dialog` -> needs permission / input |
| `Stop` / `StopFailure` | done (unseen, "ready to review") / failed; stores the final message |
| `SessionEnd` | ended; pruned after two minutes |

Status urgency orders the island: needs-permission > needs-input > failed > working > done > ended.

## IPC

Newline-delimited JSON over a Unix domain socket. The server reads connections concurrently but **delivers them to the
handler in accept order**, so back-to-back events can never be applied reversed. For a blocking request the server
keeps the socket open, watches for the hook disappearing (timeout, Ctrl-C), and writes one `HookReply` line when the
user answers.

## Usage and quota

- Per-session usage comes from the session transcript (`message.usage`, de-duplicated by `requestId` because one API
  call is written as several lines). Context size is the latest main-thread prompt size; subagent traffic is excluded.
- Cost prefers Claude Code's own `cost-state.totalCostUSD`; otherwise a price table estimate. Pricing overrides go in
  `~/Library/Application Support/Notchbot/pricing.json`, shaped like `PriceTable`:
  `{"order": ["opus"], "families": {"opus": {"input": 15, "output": 75, "cacheRead": 1.5, "cacheWrite": 18.75}}, "fallback": {...}}`.
- `UsageAggregator` sums every transcript touched in the last 8 days incrementally (offset + partial-line carry) into
  rolling 5-hour / today / 7-day token totals. "Tokens" means input + output + cache writes; cache reads are excluded
  because they dominate raw counts but barely consume quota.
- Plan-limit percentages come from `UsageAPI`: the endpoint Claude Code's `/usage` calls
  (`api.anthropic.com/api/oauth/usage`), authenticated with Claude Code's OAuth token from the `Claude Code-credentials`
  keychain item. An expired token is renewed with the refresh token and written back to that item. The app polls about
  every five minutes and on the island's refresh button (`RefreshQuotaIntent`); failures keep the last-known
  `QuotaState`, which is saved to `quota.json`. Nothing is requested on API billing. See SECURITY.md.
- The optional status line (`rate_limits`) feeds the same `QuotaState` while a terminal session answers.
  `QuotaState.parse` discovers windows by key (`five_hour`, `seven_day`, `seven_day_<model>`). A window whose reset
  time has passed reads as 0%, not a frozen number.
- Context-window size is never guessed: the status line's exact `context_window_size` wins, otherwise
  `ModelCatalog` reads `runtime.max_input_tokens` per model from Claude's own cache (`~/.claude/cache/model-catalog`).
  With neither, the context stat is omitted.
- `PlanDetector` reads `~/.claude.json` (`oauthAccount.billingType`/`organizationType`) and the environment
  (`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`) to decide between subscription (hide dollars, show quota) and API billing.

## The Live Activity

The island is a Live Activity drawn by the system, so there is no window geometry, hover handling or cutout math in
the app. `NotchActivityState.make` (core, tested) compacts the sessions, the most urgent request and the quota into a
small `Codable` state under `NotchActivityState.byteBudget`, which ActivityKit enforces. `ActivityHost` starts the
activity while the app is in the foreground, then pushes updates (with an alert when something new needs you) and a
heartbeat so the island is not shown as stale. The views live in `Shared/IslandViews.swift`, compiled into both the
widget extension and the app: the widget renders them in the island, and the app renders them offscreen for
`--snapshot`. Buttons are App Intents (`Shared/Intents.swift`) that run in the app process and resolve the exact
pending request through `PermissionBroker`; a stale or repeated tap is ignored.
