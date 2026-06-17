#!/bin/zsh
set -euo pipefail

ROOT="/Users/orb/Dev/tools/allinai-quota-menu"
SRC="${ROOT}/Assets/logo.png"
ICONSET="${ROOT}/Assets/AllinAIQuota.iconset"
CANVAS="${ROOT}/Assets/logo-1024.png"
ICNS="${ROOT}/Assets/AllinAIQuota.icns"

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

sips --cropToHeightWidth 560 560 "${SRC}" --out "${CANVAS}" >/dev/null
sips -z 1024 1024 "${CANVAS}" --out "${CANVAS}" >/dev/null

for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${CANVAS}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "${retina}" "${retina}" "${CANVAS}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "${ICNS}"
