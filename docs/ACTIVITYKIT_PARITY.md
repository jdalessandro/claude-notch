# ActivityKit rewrite: feature parity

Goal: rebuild Claude Notch's island as a Live Activity (macOS 27.3+), mirroring today's behaviour wherever the platform allows.
This table is the contract. Anything marked **Gap** or **Window** needs a decision before we build it.

**Status key**
- **Keep**: logic is unchanged (`ClaudeNotchCore`, no UI).
- **Live Activity**: renders in the system island (compact / minimal / expanded / lock-style banner).
- **Window**: moves to ordinary macOS UI (menu-bar item, detail window, Settings), because the activity can't host it.
- **Gap**: the old behaviour can't be reproduced; the closest substitute is named.
- Evidence: ✅ proven in the spike · ◻︎ expected from docs, unverified · ❌ known not to work.

## What the spike proved (and what constrains the design)

| Finding | Evidence | Consequence |
|---|---|---|
| Compact pill and the alert-expanded layout render in the physical island | ✅ | The surface is real. |
| `Activity.update` (with and without alert) works with the app in the background | ✅ | Hook events can drive updates headlessly. |
| `Activity.request` needs the app in the **foreground** (else `visibility` error 7) | ✅ | Start the activity at launch / on a click, then keep it alive for the app's lifetime. |
| Host app must be **unsandboxed** (else error 1003) | ✅ | Fine: the app already needs a Unix socket and `~/.claude` access. Not App Store eligible (it never was). |
| `Button(intent:)` needs a real team-signed build; ad-hoc signing is rejected by linkd | ✅ | Releases must be signed with a developer identity (free Personal Team works for local builds; distribution still needs a paid team and notarization). |
| `LiveActivityIntent.perform()` runs **in the host app process** | ✅ (log shows the app's pid) | Allow / Deny can resolve the pending `PermissionBroker` request directly. No IPC needed. |
| Activity lifetime, behaviour over full-screen apps, many concurrent activities | ◻︎ | Verify early in the build (see "Open questions"). |

Platform limits that shape every row below: the activity UI is a widget view, so it has **no hover, no scrolling, no text fields,
no custom panel size, no waveform animation loop**, and its content is a small `Codable` state (≈4 KB) pushed from the app.
Interaction is `Button(intent:)` and `Link` / `widgetURL` only.

## Feature table

### Always-visible status

| Today | ActivityKit design | Class |
|---|---|---|
| Collapsed island: Claude tile coloured by state (coral working / amber needs you / green done) with count badge | `compactLeading`: Claude glyph tinted by state. `compactTrailing`: count badge (needs-you count, else running count). `minimal`: tinted glyph | Live Activity |
| Live waveform that moves while an agent works | Not animatable from the activity (state-driven redraws only). Use `TimelineView`-free static glyph, or a symbol effect if the island supports it. Substitute: pulsing tint on state change | **Gap** (cosmetic) |
| Hide when idle | `Activity.end` after the idle delay; restart on next event. Must restart from the foreground, so ending hides it until the user opens the app | Live Activity, with a restart caveat (open question 2) |
| Floating vs attached style; custom width (320–350 pt) | System owns placement and size | **Gap**; remove the setting |
| Virtual island on non-notch displays | System decides where Live Activities show on displays without a cutout | ◻︎ verify |

### Expanded views

| Today | ActivityKit design | Class |
|---|---|---|
| Expand on hover with delay | System expands on its own interaction; no hover hook for us | **Gap**; remove hover settings |
| Auto-open on events (approval, finished, ...) and for N seconds | `AlertConfiguration` on `update` expands the island; the system sets the duration | Live Activity (duration not configurable) |
| Detailed view grouped Needs you / Ready to review / Working / Idle, scrollable | Expanded region shows the top N rows by priority (needs-you first), each one line. Full grouped list lives in the detail window | Live Activity (top N) + **Window** (full) |
| Compact view with inline Allow/Deny and mini plan readout | Expanded region row = name + status + `Button(intent:)` pair | Live Activity |
| Remembered compact/detailed choice and click-through between them | Only one expanded layout exists; the detailed list moves to the window | **Gap** (replaced by the window) |
| Per-session prompt, current tool, branch, elapsed, context %, lines changed | Elapsed via `Text(timerInterval:)` (system-updated, no pushes). Others as one-line detail text, truncated to fit the state budget | Live Activity (subset) |
| Subagent tree, drill-in, per-subagent last result | Count and "⑂ 2 running · 1 done" in the row. Full tree and drill-in in the window | Live Activity (count) + **Window** (tree) |
| Claude's result for review, "Mark reviewed" | Short result in the row after finish with an `Open` link; "Mark reviewed" as `Button(intent:)`. Full text in the window | Live Activity + **Window** |
| Auto-review by 5 s dwell on the detailed view | Needs pointer position; unavailable. Keep reply-in-session auto-review (hook-driven) and manual Mark reviewed | **Gap** (partial) |
| Questions rendered as questions, with choices and "Answer in Claude / Not now" | Question text plus `Open` (activates Claude) and `Not now` intents. Choices as read-only text | Live Activity |

### Approvals

| Today | ActivityKit design | Class |
|---|---|---|
| Permission request shows exact command, Allow / Deny, notes when from a subagent | Alert update with `approvalPending`; command truncated to fit; `AllowIntent` / `DenyIntent` call `PermissionBroker.resolve` in-process. Long commands link to the window | Live Activity ✅ (intent path proven) |
| Several pending approvals | One row per pending request, each with its own intent pair carrying the request id as an intent parameter | ◻︎ verify |
| Hook held up to 10 min; falls through if app is not running | Unchanged (hook + socket + broker) | Keep |
| Observe-only mode | Unchanged | Keep |

### Usage and limits

| Today | ActivityKit design | Class |
|---|---|---|
| 5-hour / weekly / per-model bars with reset times, amber at 75 %, red at 90 % | Expanded bottom region: two thin `ProgressView` bars (5 h and weekly) with colour thresholds. Per-model rows and reset detail in the window | Live Activity (two bars) + **Window** |
| Limits \| Tokens toggle | Toggle exists in the window only (no stateful controls in the activity) | **Window** |
| Cost display rules (hidden on Pro/Max) | Keep rules; shown in the window | Keep + **Window** |
| Status-line quota ingestion, persisted `quota.json` | Unchanged | Keep |

### Notifications and navigation

| Today | ActivityKit design | Class |
|---|---|---|
| Sound + system banners per event, toggleable | Keep `UNUserNotificationCenter` banners. Alert updates may also chime; avoid double-notifying by letting the alert replace the sound when the activity is live | Keep, reconcile (open question 4) |
| Click a session to jump to its terminal / app | `Button(intent:)` runs in the app process, which can call `NSWorkspace` to activate the right app. Or `Link` / `widgetURL` | Live Activity ◻︎ verify |

### Grouping and settings

| Today | ActivityKit design | Class |
|---|---|---|
| Group by project, collapsible, open-PR counts, parent/child links (PR 14) | Grouping logic is core and stays. The activity shows at most the lead project's sessions; the full grouped list is in the window | Keep + **Window** |
| Settings window (General, Content, Notifications, Integration, Advanced) | Stays a normal window. General loses island style, width, hover options; Content loses toggles the activity can't honour | Window |
| Menu-bar item, Install / Reinstall / Uninstall hooks, Update-hooks chip | Menu-bar item and Integration tab unchanged. The "Update hooks" chip moves to the menu and the window header (the activity has no room) | Window |
| Demo mode (`make demo`) | Keep. Drives the same activity with synthetic state | Keep |
| Snapshot rendering for docs | Offscreen NSHostingView of the activity views no longer matches the system chrome. Keep snapshots for the window; add manual screenshots of the real island | **Gap** (tooling) |

### Reused unchanged (`ClaudeNotchCore`)

Hook events and installer, `Session` state machine, `TranscriptTailer`, `Usage`, `Quota`, `IPC`, `PermissionBroker`, `ReviewGate`,
`ProjectGrouping`, `Preferences` (minus removed keys), `Format`, `Paths`. New core code: a pure `ActivityState` reducer that turns
`[AgentSession]` + approvals + quota into the small `NotchAttributes.ContentState`, so the compacting rules are unit-tested.
`HoverGate`, `SafeZone` and `CompactLayout` become dead code and are deleted.

## Settings that disappear

Island style, island width, collapsed view style, expand on hover, hover delay, auto-open duration, expanded view style
(compact / detailed). Existing preference files keep loading; the keys are ignored.

## Open questions to settle early (first build milestone)

1. **Lifetime.** How long does a macOS Live Activity live without app activity? If the system ends it, can the app restart it from the background (we know it can't) or only on foreground? Decides how we handle a long idle gap.
2. **Hide-when-idle.** Ending the activity means the next event can't restart it from the background. Option: never end; show a minimal glyph when idle.
3. **Many approvals / many sessions** within the state-size budget, and whether one activity or one per project is better.
4. **Double notification.** Alert chime plus system banner.
5. **Over full-screen apps** and on external displays.
6. **Distribution.** A signed, notarized build needs a paid Developer Program team. Local builds work with a Personal Team.

## Proposed build order

1. Convert to an Xcode project (app target + widget extension), reusing `ClaudeNotchCore` as a local package; keep `make` targets working through `xcodebuild`.
2. `ActivityState` reducer plus tests; wire `AppModel` to `Activity.request` / `update` / `end`.
3. Approval intents bound to `PermissionBroker`.
4. Detail window (grouped list, subagent tree, usage) reusing the existing SwiftUI list views.
5. Remove the AppKit panel and dead settings; update README, ARCHITECTURE, CHANGELOG.
6. Resolve the open questions on a real build, then adjust.
