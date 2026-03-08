#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Wallsetter}"
BIN_NAME="${BIN_NAME:-wallsetter}"
BUNDLE_ID="${BUNDLE_ID:-com.genuinebasilnt.wallsetter}"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_MODE="${BUILD_MODE:-release}" # release | debug
ICON_ICNS="${ICON_ICNS:-${ROOT_DIR}/assets/${APP_NAME}.icns}"

if [[ "${BUILD_MODE}" != "release" && "${BUILD_MODE}" != "debug" ]]; then
  echo "BUILD_MODE must be 'release' or 'debug'."
  exit 1
fi

VERSION="${VERSION:-$(cargo pkgid -p wallsetter | sed -E 's/.*#([0-9A-Za-z.-]+)$/\1/')}"
TARGET_BIN="${ROOT_DIR}/target/${BUILD_MODE}/${BIN_NAME}"

APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
STAGING_DIR="${DIST_DIR}/dmg-root"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-macOS.dmg"

echo "Building ${BIN_NAME} (${BUILD_MODE})..."
if [[ "${BUILD_MODE}" == "release" ]]; then
  cargo build --release --bin "${BIN_NAME}"
else
  cargo build --bin "${BIN_NAME}"
fi

if [[ ! -f "${TARGET_BIN}" ]]; then
  echo "Expected binary not found: ${TARGET_BIN}"
  exit 1
fi

echo "Creating .app bundle..."
rm -rf "${APP_DIR}" "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${STAGING_DIR}"

cp "${TARGET_BIN}" "${MACOS_DIR}/${BIN_NAME}"
chmod +x "${MACOS_DIR}/${BIN_NAME}"

ICON_PLIST_BLOCK=""
if [[ -f "${ICON_ICNS}" ]]; then
  cp "${ICON_ICNS}" "${RESOURCES_DIR}/${APP_NAME}.icns"
  ICON_PLIST_BLOCK="    <key>CFBundleIconFile</key>
    <string>${APP_NAME}.icns</string>"
else
  echo "Icon not found at ${ICON_ICNS}; building without bundled .icns icon."
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
${ICON_PLIST_BLOCK}
</dict>
</plist>
EOF

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Codesigning app with identity: ${SIGN_IDENTITY}"
  codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}"
fi

echo "Creating DMG at ${DMG_PATH}..."
cp -R "${APP_DIR}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Codesigning DMG with identity: ${SIGN_IDENTITY}"
  codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
fi

echo "Done:"
echo "  App: ${APP_DIR}"
echo "  DMG: ${DMG_PATH}"
