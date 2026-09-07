#!/usr/bin/env bash
# Prints the macOS SDK to build against.
#
# There is no Xcode on this machine, only Command Line Tools. From macOS 27's
# SDK, SwiftUI declares `@State` and friends as macros, and expanding a macro
# needs a compiler plugin — `libSwiftUIMacros.dylib` — that ships with Xcode
# and not with the Command Line Tools. Building against that SDK therefore
# fails with "plugin for module 'SwiftUIMacros' not found" on every `@State`.
#
# So: use the newest SDK the toolchain can actually expand. If the plugin is
# present, the newest SDK is fine. Otherwise fall back to the newest SDK from
# before the change. LUMEN_SDK overrides all of it.
set -euo pipefail

if [ -n "${LUMEN_SDK:-}" ]; then
    echo "$LUMEN_SDK"
    exit 0
fi

plugins="$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins"
if [ -f "$plugins/libSwiftUIMacros.dylib" ]; then
    xcrun --show-sdk-path
    exit 0
fi

# Newest first, skipping the versions whose SwiftUI needs the missing plugin.
for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null \
             | grep -E 'MacOSX[0-9]+\.[0-9]+\.sdk$' | sort -Vr); do
    version="$(basename "$sdk" | sed 's/MacOSX//; s/\.sdk//')"
    major="${version%%.*}"
    if [ "$major" -lt 27 ]; then
        echo "$sdk"
        exit 0
    fi
done

# Nothing older available: use what xcrun says and let the error speak.
xcrun --show-sdk-path
