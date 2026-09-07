#!/usr/bin/env bash
# Builds Lumen.app: Rust core as a static library, SwiftUI front end linked
# against it, assembled into a bundle. No Xcode required — Command Line Tools
# provide swiftc and the macOS SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Lumen.app"
CONFIG="${CONFIG:-release}"
SDK="$("$ROOT/tools/pick-sdk.sh")"
TARGET="arm64-apple-macos14.0"

echo "==> Rust core ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    cargo build -p lumen-ffi --release
    LIBDIR="$ROOT/target/release"
    SWIFT_OPT="-O"
else
    cargo build -p lumen-ffi
    LIBDIR="$ROOT/target/debug"
    SWIFT_OPT="-Onone"
fi

echo "==> Bundle skeleton"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/apps/Lumen/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/apps/Lumen/Resources/AppIcon.icns" ] && \
    cp "$ROOT/apps/Lumen/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> SwiftUI front end"
# shellcheck disable=SC2046
swiftc $SWIFT_OPT \
    -target "$TARGET" \
    -sdk "$SDK" \
    -swift-version 5 \
    -parse-as-library \
    -import-objc-header "$ROOT/apps/Lumen/include/lumen.h" \
    -o "$APP/Contents/MacOS/Lumen" \
    $(find "$ROOT/apps/Lumen/Sources" -name '*.swift' | sort) \
    -L "$LIBDIR" -llumen_ffi \
    -framework AppKit -framework SwiftUI -framework Combine \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -framework IOKit \
    -lc++ -liconv

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
    echo "    codesign unavailable; the bundle still runs locally"

echo "==> Built $APP"
