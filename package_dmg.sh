#!/bin/zsh
set -euo pipefail

APP_NAME="AllinAI Quota"
APP_VERSION="0.2.0"
APP_BUILD="2"
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${ROOT}/dist"
STAGE="${DIST}/dmg-stage"
APP="${STAGE}/${APP_NAME}.app"
DMG="${DIST}/AllinAI-Quota.dmg"
DMG_STAGE="${DIST}/.AllinAI-Quota.$$.dmg"

cleanup() {
  rm -rf "${STAGE}"
  rm -f "${DMG_STAGE}"
}
trap cleanup EXIT
rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${DIST}"

"${ROOT}/build.sh" --output "${APP}"
VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "${APP}/Contents/Info.plist")"
if [[ "${VERSION}" != "${APP_VERSION}" || "${BUILD}" != "${APP_BUILD}" ]]; then
  print -u2 'Version metadata differs between build.sh and package_dmg.sh.'
  exit 1
fi

ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG_STAGE}" >/dev/null
mv -f "${DMG_STAGE}" "${DMG}"
print "Created ${DMG}"
