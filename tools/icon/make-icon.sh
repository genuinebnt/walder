#!/usr/bin/env bash
# Regenerates apps/Lumen/Resources/AppIcon.icns from make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)/Lumen.iconset"
mkdir -p "$WORK"

swiftc -O -sdk "$(xcrun --show-sdk-path)" \
    -o "$(dirname "$WORK")/render" "$ROOT/tools/icon/make-icon.swift" \
    -framework AppKit
"$(dirname "$WORK")/render" "$WORK"

iconutil -c icns "$WORK" -o "$ROOT/apps/Lumen/Resources/AppIcon.icns"
echo "==> $ROOT/apps/Lumen/Resources/AppIcon.icns"
