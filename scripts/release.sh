#!/usr/bin/env bash
# Local release: build -> Developer ID sign (hardened runtime) -> notarize -> staple -> dmg -> GitHub Release.
# Hosted CI runners lack the macOS 27.3 SDK, so this runs on your Mac. CI only publishes the Homebrew cask afterwards.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Account Holder) and install it in your login keychain.
#   2. xcrun notarytool store-credentials claude-notch --apple-id <apple id> --team-id <TEAM> --password <app-specific pw>
#   3. If Live Activities need a provisioning profile under Developer ID, download one per bundle id and set
#      APP_PROFILE / WIDGET_PROFILE to the .provisionprofile paths.
#
# Usage: scripts/release.sh            (build, sign, notarize, dmg; stops before publishing)
#        PUBLISH=1 scripts/release.sh  (also tags vVERSION and creates the GitHub Release; needs gh)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
TEAM=${CLAUDE_NOTCH_TEAM:-$(cat .xcode-team 2>/dev/null || true)}
IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
PROFILE=${NOTARY_PROFILE:-claude-notch}
APP=dist/ClaudeNotch.app
OUT=dist/ClaudeNotch-$VERSION
[ -n "$TEAM" ] || { echo "Set CLAUDE_NOTCH_TEAM or .xcode-team"; exit 1; }
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity in the keychain"; exit 1; }
if [ "${PUBLISH:-0}" = 1 ] && [ -n "$(git status --porcelain)" ]; then echo "Working tree is dirty"; exit 1; fi

echo "==> Build ($VERSION)"
CONFIG=Release ./scripts/bundle.sh

# Signing happens inside-out. Entitlements are carried over from the repo, not scraped from the dev-signed build.
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
embed() { [ -n "${2:-}" ] && cp "$2" "$1/Contents/embedded.provisionprofile" || true; }

echo "==> Sign with: $IDENTITY"
WIDGET=$APP/Contents/PlugIns/ClaudeNotchWidget.appex
embed "$WIDGET" "${WIDGET_PROFILE:-}"
embed "$APP" "${APP_PROFILE:-}"
sign "$APP/Contents/MacOS/claude-notch-hook"
sign --entitlements Widget/Widget.entitlements "$WIDGET"
sign --entitlements App/App.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarize app"
ditto -c -k --keepParent "$APP" "$OUT.zip"
xcrun notarytool submit "$OUT.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT.zip"

echo "==> Build dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT.dmg"
hdiutil create -volname "Claude Notch" -srcfolder "$STAGE" -ov -format UDZO "$OUT.dmg"
rm -rf "$STAGE"
sign "$OUT.dmg"
xcrun notarytool submit "$OUT.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT.dmg"

echo "==> Verify like a stranger's Mac"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$OUT.dmg"
(cd dist && shasum -a 256 "ClaudeNotch-$VERSION.dmg" | tee "ClaudeNotch-$VERSION.dmg.sha256")

if [ "${PUBLISH:-0}" = 1 ]; then
  echo "==> Publish v$VERSION"
  git tag -a "v$VERSION" -m "v$VERSION" && git push origin "v$VERSION"
  gh release create "v$VERSION" "$OUT.dmg" "$OUT.dmg.sha256" --title "v$VERSION" --notes-file <(awk "/^## \\[?$VERSION/{f=1;next} /^## /{f=0} f" CHANGELOG.md)
else
  echo "Done. Re-run with PUBLISH=1 to tag and release."
fi
