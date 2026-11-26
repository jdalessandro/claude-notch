# Contributing

Thanks for helping! This is a small Swift package; everything builds with the Command Line Tools (no Xcode project).

## Setup

```bash
git clone <your fork> && cd claude-notch
make build test          # swift build && swift test
make demo                # launches the app with synthetic agents
```

Requirements: macOS 14+, Swift 6 toolchain. Heads-up: with only the Command Line Tools installed, the compiler
occasionally fails with `plugin for module 'TestingMacros' not found`. That is a toolchain flake; re-run the command.

## Layout

| Path | Contents |
|---|---|
| `Sources/ClaudeNotchCore` | Pure logic with no UI: events, session state machine, transcript/usage parsing, IPC, installer, preferences. **Everything testable lives here.** |
| `Sources/claude-notch-hook` | The forwarder Claude Code invokes. Must never block or break a session. |
| `App/` | The host app: `AppModel`, Live Activity host, *Sessions* window, settings, menu-bar item. |
| `Shared/` | Code compiled into both the app and the widget: island views, App Intents, activity attributes. |
| `Widget/` | The widget extension that draws the Live Activity. |
| `Tests/ClaudeNotchCoreTests` | Swift Testing suites, one file per area. |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data flow and design rules.

## Before you open a PR

- `make test` and `make lint` pass (`make format` fixes most style findings).
- New behavior in `ClaudeNotchCore` comes with tests. UI-only changes include a screenshot (`make snapshots`).
- Keep the hook forwarder fast and silent; anything it prints goes to Claude Code.
- Don't use `@State`/`@Binding` property wrappers in views: they are macros that require a compiler plugin the Command
  Line Tools don't ship. Keep view state in the `@Observable` models instead.
- Small, focused PRs; describe the *why*.

## Reporting bugs

Use the bug template and, if relevant, attach a redacted excerpt from the diagnostics log (see SECURITY.md).
