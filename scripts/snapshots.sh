#!/usr/bin/env bash
# Renders the demo UI to docs/screens/*.png (offscreen; needs no screen-recording permission).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
rm -rf docs/screens && mkdir -p docs/screens
.build/debug/ClaudeNotch --snapshot "$PWD/docs/screens"
ls docs/screens
