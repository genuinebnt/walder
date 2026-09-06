#!/usr/bin/env bash
# Builds Lumen and installs it to /Applications so it can be run alongside
# development. Quits a running copy first, since the bundle is replaced.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${DEST:-/Applications}"

CONFIG="${CONFIG:-release}" "$ROOT/build.sh"

if pgrep -x Lumen >/dev/null; then
    echo "==> Quitting the running copy"
    osascript -e 'tell application "Lumen" to quit' 2>/dev/null || killall Lumen 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x Lumen >/dev/null || break; sleep 0.25; done
fi

echo "==> Installing to $DEST/Lumen.app"
rm -rf "$DEST/Lumen.app"
cp -R "$ROOT/build/Lumen.app" "$DEST/Lumen.app"

# Gatekeeper flags a freshly copied unsigned bundle; the ad-hoc signature plus
# clearing the quarantine bit is enough for a locally built app.
xattr -dr com.apple.quarantine "$DEST/Lumen.app" 2>/dev/null || true
codesign --force --deep --sign - "$DEST/Lumen.app" 2>/dev/null || true

echo "==> Installed. Launch with: open -a Lumen"
