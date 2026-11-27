#!/usr/bin/env bash
# One command from your Mac: test -> build -> Developer ID sign -> notarize -> dmg -> GitHub Release -> Homebrew cask.
#
#   make release      stable release of the version in VERSION (tag vX.Y.Z), updates the Homebrew cask
#   make prerelease   signed, notarized prerelease build of HEAD (tag build-<n>), newest 15 kept, cask untouched
#   scripts/release.sh --dry-run   build, sign, notarize and verify, but publish nothing
#
# One-time setup is in docs/RELEASING.md. Everything is checked up front so a failure costs seconds, not a notarization wait.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL=stable; DRY=0
for a in "$@"; do case $a in
  --prerelease) CHANNEL=ci ;;
  --dry-run) DRY=1 ;;
  *) echo "unknown option $a"; exit 2 ;;
esac; done

VERSION=$(tr -d '[:space:]' < VERSION)
REPO=${RELEASE_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
TAP_REPO=${TAP_REPO:-${REPO%%/*}/homebrew-tap}
NOTARY_PROFILE=${NOTARY_PROFILE:-claude-notch}
SHORT_SHA=$(git rev-parse --short=7 HEAD)
if [ "$CHANNEL" = ci ]; then
  BUILD=$(git rev-list --count HEAD); LABEL="$VERSION-ci.$BUILD.$SHORT_SHA"; TAG="build-$BUILD"
else
  BUILD=$VERSION; LABEL=$VERSION; TAG="v$VERSION"
fi
APP=dist/ClaudeNotch.app
OUT=dist/ClaudeNotch-$LABEL
die() { echo "error: $*" >&2; exit 1; }

echo "==> Preflight ($CHANNEL $LABEL)"
TEAM=${CLAUDE_NOTCH_TEAM:-$(cat .xcode-team 2>/dev/null || true)}
[ -n "$TEAM" ] || die "set CLAUDE_NOTCH_TEAM or write your team id to .xcode-team"
IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
[ -n "$IDENTITY" ] || die "no 'Developer ID Application' certificate in your keychain (docs/RELEASING.md, step 1)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' missing or invalid (docs/RELEASING.md, step 2)"
if [ "$DRY" = 0 ]; then
  gh auth status >/dev/null 2>&1 || die "run: gh auth login"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes: commit or stash first"
  git fetch -q origin
  git branch -r --contains HEAD | grep -q . || die "HEAD is not pushed: push it so the release points at a public commit"
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && die "release $TAG already exists (bump VERSION?)"
  if [ "$CHANNEL" = stable ]; then
    grep -qE "^## \[?$VERSION" CHANGELOG.md || die "CHANGELOG.md has no '## [$VERSION]' section"
    gh repo view "$TAP_REPO" >/dev/null 2>&1 || die "tap repo $TAP_REPO not found"
  fi
fi

echo "==> Test"
make test

echo "==> Build"
CONFIG=Release ./scripts/bundle.sh
WIDGET=$APP/Contents/PlugIns/ClaudeNotchWidget.appex
stamp() { # before signing: any later edit would break the signature
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$1" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$1" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$1"
}
stamp "$APP/Contents/Info.plist"; stamp "$WIDGET/Contents/Info.plist"

# Inside-out. Entitlements come from the repo, not from the development-signed build.
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
embed() { [ -n "${2:-}" ] && cp "$2" "$1/Contents/embedded.provisionprofile" || true; }
echo "==> Sign: $IDENTITY"
embed "$WIDGET" "${WIDGET_PROFILE:-}"; embed "$APP" "${APP_PROFILE:-}"   # Developer ID provisioning profiles, if Live Activities need them
sign "$APP/Contents/MacOS/claude-notch-hook"
sign --entitlements Widget/Widget.entitlements "$WIDGET"
sign --entitlements App/App.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarize app"
ditto -c -k --keepParent "$APP" "$OUT.zip"
xcrun notarytool submit "$OUT.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"; rm "$OUT.zip"

echo "==> dmg"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$OUT.dmg"; hdiutil create -volname "Claude Notch" -srcfolder "$STAGE" -ov -format UDZO "$OUT.dmg"; rm -rf "$STAGE"
sign "$OUT.dmg"
xcrun notarytool submit "$OUT.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT.dmg"

echo "==> Verify like a stranger's Mac"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$OUT.dmg"
(cd dist && shasum -a 256 "ClaudeNotch-$LABEL.dmg" > "ClaudeNotch-$LABEL.dmg.sha256" && cat "ClaudeNotch-$LABEL.dmg.sha256")
SHA=$(cut -d' ' -f1 "$OUT.dmg.sha256")

if [ "$DRY" = 1 ]; then echo "Dry run: built $OUT.dmg, nothing published."; exit 0; fi

echo "==> Publish $TAG"
if [ "$CHANNEL" = ci ]; then
  gh release create "$TAG" "$OUT.dmg" "$OUT.dmg.sha256" --repo "$REPO" --target "$(git rev-parse HEAD)" --prerelease \
    --title "Build $BUILD ($SHORT_SHA)" --notes "Automated build of \`$SHORT_SHA\`. Signed and notarized; not a stable release."
  gh release list --repo "$REPO" --limit 200 --json tagName,isPrerelease \
    --jq '[.[] | select(.isPrerelease and (.tagName|startswith("build-")))] | .[15:] | .[].tagName' \
    | xargs -I{} gh release delete {} --repo "$REPO" --cleanup-tag --yes
else
  awk "/^## \\[?$VERSION/{f=1;next} /^## /{f=0} f" CHANGELOG.md > "$OUT.notes.md"
  gh release create "$TAG" "$OUT.dmg" "$OUT.dmg.sha256" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "$TAG" --notes-file "$OUT.notes.md"
  echo "==> Update Homebrew cask in $TAP_REPO"
  TAP=$(mktemp -d)
  gh repo clone "$TAP_REPO" "$TAP" -- -q
  mkdir -p "$TAP/Casks"
  sed -e "s/\"VERSION\"/\"$VERSION\"/" -e "s/\"SHA256\"/\"$SHA\"/" packaging/claude-notch.rb.template > "$TAP/Casks/claude-notch.rb"
  git -C "$TAP" add Casks/claude-notch.rb
  git -C "$TAP" diff --cached --quiet || { git -C "$TAP" commit -q -m "claude-notch $VERSION" && git -C "$TAP" push -q; }
  rm -rf "$TAP"
fi
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
