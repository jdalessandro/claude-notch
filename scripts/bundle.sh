#!/usr/bin/env bash
# Builds dist/ClaudeNotch.app (menu-bar-only agent app) with the hook binary alongside it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/ClaudeNotch.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$BIN/ClaudeNotch" "$BIN/claude-notch-hook" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.claude-notch.app</string>
  <key>CFBundleName</key><string>Claude Notch</string>
  <key>CFBundleExecutable</key><string>ClaudeNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "Built $APP"
