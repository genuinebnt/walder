#!/usr/bin/env bash
# Builds Lumen and installs it to /Applications so it can be run alongside
# development, and puts lumen-cli somewhere on the PATH. Quits a running copy
# first, since the bundle is replaced.
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

echo "==> Building lumen-cli"
cargo build --release --manifest-path "$ROOT/Cargo.toml" -p lumen-cli

# /usr/local/bin when it is writable without sudo, otherwise the per-user
# equivalent — installing the CLI should not need a password.
if [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
fi
install -m 755 "$ROOT/target/release/lumen-cli" "$BIN_DIR/lumen-cli"
echo "==> Installed $BIN_DIR/lumen-cli"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "    (add it to your PATH: export PATH=\"$BIN_DIR:\$PATH\")" ;;
esac

echo "==> Installed. Launch with: open -a Lumen"
