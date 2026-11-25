# Architecture

```
claude (CLI / desktop)                              ClaudeNotch.app
   | hook event (stdin JSON)                          |- NotchServer     Unix socket (0600), ordered delivery
   v                                                  |- SessionStore    pure reducer: events -> sessions
claude-notch-hook --- notch.sock --------------->     |- TranscriptTailer  per-session usage / title / cost
   ^  PermissionRequest: blocks until answered        |- UsageAggregator   quota windows from all transcripts
   '------------- Allow / Deny <---------------       `- NotchController   NSPanel at the cutout + SwiftUI
claude status line --- claude-notch-hook --statusline -->  QuotaState (rate limits, exact context window)
```

## Modules

- **ClaudeNotchCore** has no UI dependencies. `SessionStore.apply(_:)` is a pure function of (state, event), so the whole
  state machine is unit-tested without a display. IPC, the settings-file installer, transcript parsing and
  preferences are also here.
- **claude-notch-hook** reads one JSON event on stdin, sends it, and exits 0. Only `PermissionRequest` (with
  `--interactive`) waits for a reply, which it prints in Claude Code's decision schema.
- **ClaudeNotch** owns presentation. `AppModel` (`@Observable`) is the single source of truth for views.

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
  `~/Library/Application Support/ClaudeNotch/pricing.json`, shaped like `PriceTable`:
  `{"order": ["opus"], "families": {"opus": {"input": 15, "output": 75, "cacheRead": 1.5, "cacheWrite": 18.75}}, "fallback": {...}}`.
- `UsageAggregator` sums every transcript touched in the last 8 days incrementally (offset + partial-line carry) into
  rolling 5-hour / today / 7-day token totals. "Tokens" means input + output + cache writes; cache reads are excluded
  because they dominate raw counts but barely consume quota.
- Real quota percentages only exist in Claude Code's status line (`rate_limits`). `QuotaState.parse` discovers windows
  by key (`five_hour`, `seven_day`, `seven_day_<model>`), so per-model limits appear automatically.
- `PlanDetector` reads `~/.claude.json` (`oauthAccount.billingType`/`organizationType`) and the environment
  (`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`) to decide between subscription (hide dollars, show quota) and API billing.

## Hover and layout

Opening and closing from SwiftUI `onHover` on the animating shape feeds back on itself. Instead, `NotchController`
samples the real pointer position at 20 Hz against the island's **final** rectangle and passes it through `HoverGate`
(dwell to open, grace period to close). Animations use one critically damped curve with no overshoot, list heights are
measured and quantized, and while collapsed the transparent window margins are click-through.

## Safe zone around the cutout

The header row shares its band with the opaque hardware cutout. `SafeZone.sideWidth` (core, tested) gives each side of the
header the width left beside the cutout after a margin and the island's outer padding. `NotchHeaderRow` limits the left
and right groups to that width, and each group lists its wordings longest-first inside a `ViewThatFits`. The title is two lines when subagents run
("3 agents" over "2 subagents running"), and degrades by dropping the decorative sparkle first, then folding to one
line ("3 agents · 2 sub"), then shortening the words; tokens + icons degrade to icons. Text degrades instead of running
underneath the cutout. The cutout width the app measures already includes a margin, so `SafeZone.cutoutMargin` is only a
small extra clearance (a large one would waste room and force terse wording). To check a
layout, run `CLAUDE_NOTCH_SNAPSHOT_DEBUG=1 .build/debug/ClaudeNotch --snapshot <dir>`: it renders the headers with the
cutout drawn in red, at the real width and at a much wider one.

## Geometry

`NotchGeometry` reads `NSScreen.safeAreaInsets` and the auxiliary areas for the cutout. The floating style offsets
the pill by ~19% of the reserved band, matching the hardware island; the attached style fuses with the top edge.
