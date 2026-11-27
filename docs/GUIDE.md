# NotchBot user guide

Everything you can see, change and troubleshoot. New here? Start with the [README](../README.md).

- [Using the island](#using-the-island)
- [Settings reference](#settings-reference)
- [Approving permissions from the island](#approving-permissions-from-the-island)
- [Plan limits](#plan-limits)
- [Claude desktop app and the terminal](#claude-desktop-app-and-the-terminal)
- [Updating and uninstalling](#updating-and-uninstalling)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

## Using the island

NotchBot draws a macOS Live Activity beside the camera cutout. The system owns its shape, position and expansion, so
there is no hover or scrolling inside it; you interact with buttons.

**Compact view.** Logo on the left, waveform on the right: one bar per working session, thinner bars for subagents.
Grey = agents are working, orange = something needs you, dots = idle. An optional blue badge on the logo counts results
you haven't reviewed. Green is Allow, red is Deny, failed or destructive.

**Expanded view.** It opens by itself when something needs you. From top to bottom:

1. **Header**: total agents, how many need you, how many are working, and how many subagents run.
2. **The most urgent request**, featured: a permission request (exact command, **Allow / Deny**), or a question (its
   choices, **Answer in Claude** / **Not now**). Urgency order: needs permission, needs input, failed, working, done, ended.
3. **Session cards** (up to three per page, two at the *Large* and *Larger* sizes): name, branch, status, elapsed time,
   your prompt, current tool, context use, lines changed, tool calls, token count, and a subagent summary
   ("2 running · 1 done"). Tap a card's **Subagents** header to expand every subagent with what it is doing, its tool-call
   count and its last result. Other waiting sessions show **Review**, which moves their request to the main card; approvals are answered only there.
4. **Footer**: plan limits with reset countdowns, a refresh button, the page indicator, and (if hooks are missing or
   outdated) an **Install hooks** / **Update hooks** button. The gear opens Settings; **⋯** has *Settings…*,
   *Mark all reviewed* and *Quit NotchBot*.

**Finished turns.** When a turn ends, the card shows Claude's result and stays *Ready to review* until you reply in that
session, tap **Done**/**Mark reviewed**, or use **Mark all reviewed**. **Open** jumps to the app the session runs in.

**Subagents.** A session whose main turn ended while subagents still run stays *Working* ("Waiting on 2 subagents") and
is only marked finished, with its notification, when the last one stops. A subagent silent for 15 minutes is treated as
finished so nothing can stay stuck.

## Settings reference

Open Settings from the island's gear icon or **⋯** menu, the menu-bar icon, or ⌘, while NotchBot is active. Changes
apply immediately and persist.

### General

| Setting | Default | What it does |
|---|---|---|
| **Island size** | Default | Five steps: *Smaller*, *Small*, *Default*, *Large*, *Larger* (type and icons at 94%, 100%, 112%, 125%, 140%). *Large* and *Larger* show two session cards per page instead of three. |
| **Show a review badge on the logo** | On | A red count on the compact logo for results waiting for review. |
| **Menu bar in fullscreen** | n/a | Shows whether macOS is set to never hide the menu bar, which keeps the island visible in fullscreen apps. **Open System Settings** jumps to the pane; NotchBot only reads this setting. |
| **Raise the island when something needs you** | On | Also raises the island when a turn finishes with a result to review. Permission requests, questions, sessions waiting for input and failed turns always raise it. |
| **Forget idle sessions after** | 12 hours | 1 hour, 4 hours, 12 hours or 1 day. An idle session drops off the island after this long. |

### Content

| Setting | Default | What it does |
|---|---|---|
| **Show on each session**: your prompt, subagents, context meter and changed lines, usage and quota | All on | Hide the parts you don't want on session cards and the usage footer. Names, branch, status, requests and the plan-limit footer's essentials stay. |
| **Usage card shows** | Plan limits (%) | Percentages or token counts. You can also flip it on the card itself. |
| **Dollar cost** | Automatic | *Automatic* hides dollars on Pro and Max and shows them on API billing; *Always* / *Never* override. |
| **Detected plan** | n/a | Read-only: the plan NotchBot detected from Claude Code's login (`~/.claude.json`) and environment. |

### Notifications

| Setting | Default | What it does |
|---|---|---|
| **Notify me when**: approval needed, waiting for your input, turn finished, turn failed | All on | Which events alert you. |
| **Play a sound** | On | A chime with the alert. |
| **Show system notifications** | On | Banners in Notification Center. |
| **Include details in banners** | On | Puts the command or a snippet of Claude's reply in the banner. Turn off if banners can appear on a screen others see. |

### Integration

| Setting | Default | What it does |
|---|---|---|
| **Claude Code hooks** | Not installed | **Install hooks**, **Reinstall** (also applies updates) and **Uninstall**. |
| **Approve permissions from the island** | On | The island holds Claude's permission prompt until you tap **Allow** / **Deny**. Off is observe-only: the normal terminal prompt appears and you are still notified. |
| **Quota gauges** | Off | Registers NotchBot as Claude Code's status line so it can report exact context-window size and plan limits while a terminal session answers. Only installed if you don't already have a status line; an existing one is never replaced. Optional: plan limits come from the usage API either way. |

### Advanced

| Setting | Default | What it does |
|---|---|---|
| **Log raw hook events** | Off | Writes every hook event to `~/Library/Application Support/Notchbot/events.jsonl`. It contains prompts and tool inputs: keep it private. **Show log in Finder** reveals it. |
| **Reset all settings…** | n/a | Restores every default above. Hooks and the status line are left as they are. |

## Approving permissions from the island

With *Approve permissions from the island* on (the default), Claude's prompt waits for your **Allow** or **Deny**:

- Claude waits up to Claude Code's 10-minute hook timeout, and the terminal prompt doesn't appear meanwhile.
- If NotchBot isn't running, the hook exits immediately and the normal prompt appears. It never blocks a session.
- Questions (`AskUserQuestion`) are answered in Claude itself: **Answer in Claude** opens the session.
- A stale or repeated tap is ignored: each button resolves the exact request it was shown for.
- Prefer the terminal? Turn the setting off for observe-only mode.

## Plan limits

On Pro and Max, the numbers come from the same request Claude Code's `/usage` makes
(`api.anthropic.com/api/oauth/usage`), authenticated with **Claude Code's own login** from your keychain. macOS asks once
to allow access to the `Claude Code-credentials` item. NotchBot refreshes about every five minutes and whenever you tap
the refresh button; the last numbers are saved and survive restarts, and a failed request keeps them. A window whose
reset time has passed shows 0% rather than a frozen number. Nothing is requested on API (pay-as-you-go) billing, which
has no plan limits.

Bars are grey, orange from 75% and red from 90% (with a "!" at red). The **Limits | Tokens** toggle switches to token totals for the last
5 hours, today and 7 days (input + output + cache writes; cache reads are excluded because they barely use quota).

> **Privacy.** This is the only network request NotchBot makes. The token is sent only to Anthropic and never logged.
> When the login has expired, NotchBot renews it and writes the new credentials back to the same keychain item, which can
> occasionally make Claude Code ask you to sign in again. The endpoint isn't a documented API and may change. See
> [SECURITY.md](../SECURITY.md).

**Quota gauges (optional).** Turning on *Settings ▸ Integration ▸ Quota gauges* adds a status-line report that also
supplies the exact context-window size, but only while a *terminal* Claude Code session responds. Without it, the
context size comes from Claude's own model catalog (`~/.claude/cache/model-catalog`), and the stat is omitted if neither
is available.

## Claude desktop app and the terminal

Sessions from the Claude desktop app's Code tab fire the same hooks and write the same transcripts, so they appear
beside CLI sessions. They don't report which terminal they run in, so **Open** brings up the Claude app. For terminal
sessions it activates the terminal app (it can't focus a specific tab).

## Updating and uninstalling

- **App updates:** `brew upgrade --cask notchbot`, or re-run the install script, or install the new DMG. The forwarder
  that hooks call is refreshed on launch after an update.
- **Hooks update:** if your hooks were installed by an older version and miss events (such as `SubagentStart`), the footer
  shows **Update hooks** and *Settings ▸ Integration* offers **Reinstall**.
- **Uninstall:** *Settings ▸ Integration ▸ Uninstall* removes NotchBot's hooks (and its status line, if it installed it)
  from `~/.claude/settings.json`. Then delete the app or run `brew uninstall --cask notchbot`. Your original settings are
  backed up once at `settings.json.notchbot.bak`. Optionally remove `~/Library/Application Support/Notchbot`.

## Troubleshooting

| Symptom | Try |
|---|---|
| Nothing appears | Is the app running (menu-bar robot)? Are hooks installed (*Settings ▸ Integration*)? Restart Claude sessions started before installing. |
| Island disappears in a fullscreen app | macOS hides the menu bar there, and the island with it. Set System Settings ▸ Control Center ▸ "Automatically hide and show the menu bar" to **Never** (*Settings ▸ General ▸ Fullscreen* opens the pane). |
| Island missing | Quit and reopen NotchBot. Starting a Live Activity needs the app in the foreground, so it can't restart itself from the background. |
| Footer says **Update hooks**, or subagents show up late | Your hooks are from an older version. Click **Update hooks** (or *Settings ▸ Integration ▸ Reinstall*). |
| Allow / Deny do nothing | Release builds are fine. A build from source must be signed with a real team; ad-hoc signed builds can't run App Intents. |
| No plan-limit percentages | Limits exist only for Pro/Max. Allow keychain access when macOS asks, then tap refresh. If you're offline or the endpoint changed, the last-known numbers stay. Use the **Tokens** toggle meanwhile. |
| Dollars shown or hidden unexpectedly | *Settings ▸ Content ▸ Dollar cost*. |
| Terminal prompt shows instead of the island | *Approve permissions from the island* is off, or NotchBot isn't running. |
| Want to see raw events | *Settings ▸ Advanced ▸ Log raw hook events* (the log contains prompts: keep it private). |

Still stuck? [Open an issue](https://github.com/jdalessandro/notchbot/issues) and attach a redacted excerpt of the event log.

## Limitations

- macOS 27.3+ only; the system owns the island (no hover, scrolling or text entry), and the activity can only be
  (re)started while the app is in the foreground.
- The status line, if enabled, reports only while a terminal session answers.
- Clicking a session activates its app but cannot focus a specific terminal tab.
- Plan limits rely on an undocumented endpoint and may break if it changes.
- Claude Code's transcript and hook formats are internal and may change between versions.
