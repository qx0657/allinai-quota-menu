#!/bin/zsh
set -euo pipefail

APP_NAME="AllinAI Quota"
ROOT="/Users/orb/Dev/tools/allinai-quota-menu"
DIST="${ROOT}/dist"
STAGE="${DIST}/dmg-stage"
APP="${STAGE}/${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"
DMG="${DIST}/AllinAI-Quota.dmg"
VOLUME_NAME="AllinAI Quota"

rm -rf "${STAGE}" "${DMG}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${DIST}"

"${ROOT}/make_icon.sh"
cp "${ROOT}/Assets/AllinAIQuota.icns" "${APP}/Contents/Resources/AllinAIQuota.icns"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
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
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

swiftc "${ROOT}/Sources/AllinAIQuotaMenu.swift" -framework Security -o "${BIN}"
chmod +x "${BIN}"
plutil -lint "${APP}/Contents/Info.plist" >/dev/null

ln -s /Applications "${STAGE}/Applications"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  "${DMG}" >/dev/null

rm -rf "${STAGE}"
echo "Created ${DMG}"
