#!/usr/bin/env bash
# End to end: bump the version, date the changelog, merge the bump, then build, sign, notarize and publish
# (GitHub Release + dmg + checksum + Homebrew cask) and check that every channel serves the new version.
#
#   make ship BUMP=patch|minor|major|X.Y.Z|current
#   scripts/ship.sh <bump> --plan      print what would happen, change nothing
#
# `current` releases the version already in VERSION (the first release). Needs: gh (admin on the repo, since main is
# protected and the bump PR is merged with --admin), the Developer ID certificate and the notarytool profile
# (docs/RELEASING.md). release.sh does the build and publishing; this script wraps it.
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP=${1:-}; PLAN=0; [ "${2:-}" = --plan ] && PLAN=1
[ -n "$BUMP" ] || { echo "usage: scripts/ship.sh <patch|minor|major|X.Y.Z|current> [--plan]"; exit 2; }
die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

CUR=$(tr -d '[:space:]' < VERSION)
[[ $CUR =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "VERSION '$CUR' is not X.Y.Z"
MA=${BASH_REMATCH[1]}; MI=${BASH_REMATCH[2]}; PA=${BASH_REMATCH[3]}
case $BUMP in
  patch) NEW=$MA.$MI.$((PA+1)) ;;
  minor) NEW=$MA.$((MI+1)).0 ;;
  major) NEW=$((MA+1)).0.0 ;;
  current) NEW=$CUR ;;
  [0-9]*.[0-9]*.[0-9]*) NEW=$BUMP ;;
  *) die "bump must be patch, minor, major, current or X.Y.Z" ;;
esac
[[ $NEW =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad version '$NEW'"
TAG=v$NEW
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
TAP_REPO=${TAP_REPO:-${REPO%%/*}/homebrew-notchbot}
TODAY=$(date +%Y-%m-%d)

# CHANGELOG: the section for NEW must exist and be undated ("Unreleased"), or a bare [Unreleased] section is renamed.
changelog_action() {
  if grep -qE "^## \[$NEW\] - Unreleased" CHANGELOG.md; then echo "date"
  elif grep -qE "^## \[Unreleased\]" CHANGELOG.md; then echo "rename"
  elif grep -qE "^## \[$NEW\] - [0-9]{4}-" CHANGELOG.md; then echo "dated"
  else echo "missing"; fi
}
ACTION=$(changelog_action)

say "Plan: $CUR -> $NEW ($TAG), changelog: $ACTION, repo $REPO, tap $TAP_REPO"
[ "$ACTION" != missing ] || die "CHANGELOG.md has no '## [$NEW]' or '## [Unreleased]' section to release"
[ "$NEW" = "$CUR" ] || [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | tail -1)" = "$NEW" ] || die "$NEW is lower than $CUR"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && die "release $TAG already exists"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"

if [ "$PLAN" = 1 ]; then
  echo "Would: branch release/$TAG -> VERSION=$NEW, changelog $ACTION -> PR -> merge (admin) -> release.sh -> verify channels."
  [ -z "$(git status --porcelain --untracked-files=no)" ] || echo "(note: working tree has uncommitted changes; the real run refuses that)"
  exit 0
fi

say "Preflight"
gh auth status >/dev/null 2>&1 || die "run: gh auth login"
[ "$(git branch --show-current)" = main ] || die "run from main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes: commit or stash first"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not at origin/main: pull or push first"

if [ "$NEW" != "$CUR" ] || [ "$ACTION" != dated ]; then
  say "Version bump PR"
  BR=release/$TAG
  git checkout -q -b "$BR"
  echo "$NEW" > VERSION
  python3 - "$NEW" "$TODAY" "$ACTION" <<'PY'
import re, sys
new, today, action = sys.argv[1:]
s = open("CHANGELOG.md").read()
if action == "date":
    s = s.replace(f"## [{new}] - Unreleased", f"## [{new}] - {today}", 1)
elif action == "rename":
    s = s.replace("## [Unreleased]", f"## [{new}] - {today}", 1)
open("CHANGELOG.md", "w").write(s)
PY
  git add VERSION CHANGELOG.md
  git commit -q -m "Release $TAG"
  git push -q -u origin "$BR"
  PR=$(gh pr create --base main --head "$BR" --title "Release $TAG" --body "Version bump and changelog for $TAG, created by scripts/ship.sh.")
  gh pr merge "$PR" --squash --admin --delete-branch
  git checkout -q main
  git pull -q --ff-only origin main
  git branch -D "$BR" -q 2>/dev/null || true
fi

say "Release $TAG"
./scripts/release.sh

say "Verify the channels"
DMG="Notchbot-$NEW.dmg"
URL="https://github.com/$REPO/releases/download/$TAG/$DMG"
WANT=$(curl -fsSL "$URL.sha256" | cut -d' ' -f1)
GOT=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
[ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || die "dmg download does not match its checksum"
echo "dmg:   $URL (checksum ok)"
LATEST=$(gh api "repos/$REPO/releases/latest" -q .tag_name)
[ "$LATEST" = "$TAG" ] || die "releases/latest is $LATEST, curl installer would fetch the wrong version"
echo "curl:  installer will fetch $LATEST"
CASK=$(gh api "repos/$TAP_REPO/contents/Casks/notchbot.rb" -q .content | base64 --decode)
echo "$CASK" | grep -q "version \"$NEW\"" && echo "$CASK" | grep -q "sha256 \"$WANT\"" || die "cask in $TAP_REPO does not match $NEW"
echo "brew:  $TAP_REPO cask is $NEW (checksum ok)"
say "Shipped $TAG: https://github.com/$REPO/releases/tag/$TAG"
