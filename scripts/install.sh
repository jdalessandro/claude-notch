#!/usr/bin/env bash
# Installs the latest signed, notarized Notchbot release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/jdalessandro/notchbot/main/scripts/install.sh | bash
# Set VERSION=1.2.3 to pin a release. Nothing here needs Xcode or a developer account.
set -euo pipefail

REPO=jdalessandro/notchbot
[ "$(uname -s)" = Darwin ] || { echo "Notchbot is macOS only."; exit 1; }

if [ -n "${VERSION:-}" ]; then TAG="v${VERSION#v}"; else
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
fi
[ -n "$TAG" ] || { echo "No release found."; exit 1; }
V=${TAG#v}

TMP=$(mktemp -d)
MNT=""
trap '[ -n "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null; rm -rf "$TMP"' EXIT

echo "==> Downloading Notchbot $V"
BASE="https://github.com/$REPO/releases/download/$TAG"
curl -fsSL -o "$TMP/app.dmg" "$BASE/Notchbot-$V.dmg"
curl -fsSL -o "$TMP/app.dmg.sha256" "$BASE/Notchbot-$V.dmg.sha256"

echo "==> Verifying checksum"
[ "$(shasum -a 256 "$TMP/app.dmg" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$TMP/app.dmg.sha256")" ] \
  || { echo "Checksum mismatch; aborting."; exit 1; }

echo "==> Installing to /Applications"
MNT=$(hdiutil attach "$TMP/app.dmg" -nobrowse -readonly | sed -n 's#.*\(/Volumes/.*\)#\1#p' | tail -1)
pkill -x Notchbot 2>/dev/null || true
rm -rf /Applications/Notchbot.app
cp -R "$MNT/Notchbot.app" /Applications/
spctl --assess --type execute /Applications/Notchbot.app

open /Applications/Notchbot.app
echo "Done. Click 'Install hooks' in the window that opens."
