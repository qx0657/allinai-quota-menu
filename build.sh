#!/bin/zsh
set -euo pipefail

APP_NAME="AllinAI Quota"
APP_VERSION="0.1.0"
APP_BUILD="1"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"

mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

"${ROOT}/make_icon.sh"
cp "${ROOT}/Assets/AllinAIQuota.icns" "${APP}/Contents/Resources/AllinAIQuota.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AllinAI Quota</string>
  <key>CFBundleIdentifier</key>
  <string>local.allinai.quota.menu</string>
  <key>CFBundleName</key>
  <string>AllinAI Quota</string>
  <key>CFBundleDisplayName</key>
  <string>AllinAI Quota</string>
  <key>CFBundleIconFile</key>
  <string>AllinAIQuota</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

swiftc "${ROOT}/Sources/AllinAIQuotaMenu.swift" -framework Security -o "${BIN}"
chmod +x "${BIN}"
plutil -lint "${APP}/Contents/Info.plist" >/dev/null
