#!/usr/bin/env bash
# Compiles the verify harness against the app's own model sources and the real
# Rust core, then runs it. Read the summary line, not the exit code.
set -euo pipefail

# --fast skips everything that talks to Wallhaven, for a quick pass during
# development. The full run is what should pass before committing.
if [ "${1:-}" = "--fast" ]; then
    export LUMEN_VERIFY_NETWORK=0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/verify"
SDK="$(xcrun --show-sdk-path)"

cargo build -p lumen-ffi --quiet
mkdir -p "$ROOT/build"

swiftc -Onone \
    -target arm64-apple-macos14.0 \
    -sdk "$SDK" \
    -swift-version 5 \
    -import-objc-header "$ROOT/apps/Lumen/include/lumen.h" \
    -o "$OUT" \
    "$ROOT/apps/Lumen/Sources/Design/Theme.swift" \
    "$ROOT/apps/Lumen/Sources/Model/Models.swift" \
    "$ROOT/apps/Lumen/Sources/Model/LumenCore.swift" \
    "$ROOT/apps/Lumen/Sources/Model/Keychain.swift" \
    "$ROOT/apps/Lumen/Sources/Model/Store.swift" \
    "$ROOT/apps/Lumen/Sources/Model/WallpaperSetter.swift" \
    "$ROOT/apps/Lumen/Sources/Model/MenuBarLegibility.swift" \
    "$ROOT/apps/Lumen/Sources/Model/WallpaperMetadata.swift" \
    "$ROOT/apps/Lumen/Sources/Model/RadarNotifier.swift" \
    "$ROOT/apps/Lumen/Sources/Model/SystemAccent.swift" \
    "$ROOT/apps/Lumen/Sources/Model/ImagePrints.swift" \
    "$ROOT/apps/Lumen/Sources/Model/SimilarityGraph.swift" \
    "$ROOT/apps/Lumen/Sources/Model/ImageCache.swift" \
    "$ROOT/apps/Lumen/Sources/Views/PreviewPane.swift" \
    "$ROOT/apps/Lumen/Sources/Views/MasonryGrid.swift" \
    "$ROOT/apps/Lumen/Sources/Views/FiltersPopover.swift" \
    "$ROOT/tools/verify/main.swift" \
    -L "$ROOT/target/debug" -llumen_ffi \
    -framework AppKit -framework SwiftUI -framework Combine \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -framework IOKit \
    -lc++ -liconv

exec "$OUT"
