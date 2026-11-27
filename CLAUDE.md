# NotchBot

Swift package (`Sources/NotchbotCore`, `Sources/notchbot-hook`) plus a signed app and Live Activity widget. See
CONTRIBUTING.md for layout and build steps.

## Rules for changes

- **Branch names**: `<type>/<short-kebab-description>` with type `feat`, `fix`, `chore`, `docs` or `refactor` (`release/` is
  reserved for `make ship`). Never open a PR from a generated name such as `claude/<slug>-<hash>`: rename the branch first
  (`git branch -m`, and the GitHub rename API if it is already pushed).
- Before pushing: `make format && make lint && make test`. UI changes also re-render `make snapshots` and commit the
  changed `docs/screens/*.png`.
- PRs are squash-merged; keep the title short and in the style of the log (`Island: ...`, `Add ...`).
- Never commit signing team ids (`.xcode-team` stays local; pass `NOTCHBOT_TEAM` for one-off builds).
