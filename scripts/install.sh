#!/bin/zsh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright © 2026 Jean-Christophe Baptiste
# Build Studio EQ (Release), copy it to /Applications and (re)start it. Local use only: this
# signs with the developer's own identity. Distribution builds come from the release workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate --quiet
APP=build/DerivedData/Build/Products/Release/StudioEQ.app
LOG=build/install-build.log
mkdir -p build
rm -rf "$APP"   # never install a stale product if this build fails
if ! xcodebuild -project StudioEQ.xcodeproj -scheme StudioEQ -configuration Release \
       -derivedDataPath build/DerivedData build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u >&2 || true
  echo "Build failed, nothing installed (full log: $LOG)" >&2
  exit 1
fi
codesign --verify --strict "$APP"
mkdir -p dist && rm -rf dist/StudioEQ.app && cp -R "$APP" dist/
pkill -x StudioEQ 2>/dev/null || true
rm -rf /Applications/StudioEQ.app && cp -R "$APP" /Applications/
open /Applications/StudioEQ.app
echo "Installed /Applications/StudioEQ.app"
