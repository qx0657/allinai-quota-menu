#!/bin/zsh
set -euo pipefail

APP_NAME="AllinAI Quota"
APP_VERSION="0.1.0"
APP_BUILD="1"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/${APP_NAME}.app"

if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--output" || "$2" != /*.app ]]; then
    print -u2 'Usage: ./build.sh [--output /absolute/path/AllinAI Quota.app]'
    exit 2
  fi
  APP="$2"
fi

mkdir -p "${APP:h}"
BUILD_STAGE="$(mktemp -d "${APP:h}/.allinai-build.XXXXXX")"
PREVIOUS_APP=""
cleanup() {
  if [[ -n "${PREVIOUS_APP}" && -e "${PREVIOUS_APP}" ]]; then
    if [[ ! -e "${APP}" ]]; then
      mv "${PREVIOUS_APP}" "${APP}"
    else
      rm -rf "${PREVIOUS_APP}"
    fi
  fi
  rm -rf "${BUILD_STAGE}"
}
trap cleanup EXIT

BUNDLE="${BUILD_STAGE}/${APP_NAME}.app"
BIN="${BUNDLE}/Contents/MacOS/${APP_NAME}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
"${ROOT}/make_icon.sh"
cp "${ROOT}/Assets/AllinAIQuota.icns" "${BUNDLE}/Contents/Resources/AllinAIQuota.icns"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>local.allinai.quota.menu</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AllinAIQuota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O "${ROOT}/Sources/AllinAIQuotaMenu.swift" -framework Security -o "${BIN}"
chmod +x "${BIN}"
plutil -lint "${BUNDLE}/Contents/Info.plist" >/dev/null

# Compile and validate first, then replace the bundle on the same volume.
if [[ -e "${APP}" ]]; then
  PREVIOUS_APP="${BUILD_STAGE}/previous.app"
  mv "${APP}" "${PREVIOUS_APP}"
fi
mv "${BUNDLE}" "${APP}"
print "Built ${APP}"
