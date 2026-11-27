#!/usr/bin/env bash
# Builds dist/Notchbot.app: the Live Activity host app with its widget extension and the hook forwarder.
# Needs Xcode 27.3+ (ActivityKit on macOS) and a signing team: set NOTCHBOT_TEAM or put the team id in .xcode-team.
# Live Activity buttons (Allow / Deny) only work in a build signed with a real team; ad-hoc signing is rejected by the system.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-Release}
python3 scripts/gen_xcodeproj.py
xcodebuild -project Notchbot.xcodeproj -scheme Notchbot -configuration "$CONFIG" -derivedDataPath build \
  -allowProvisioningUpdates build | grep -E "error|warning: .*sign|BUILD" || true
APP="build/Build/Products/$CONFIG/Notchbot.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }
rm -rf dist && mkdir -p dist && cp -R "$APP" dist/
echo "Built dist/Notchbot.app"
