#!/bin/bash
# Builds dist/KalanoroTogether-<version>.zip: installer + UE4SS runtime + the KalanoroCoop and KalanoroFix mods.
set -e
cd "$(dirname "$0")"
VERSION="${1:-1.0}"
UE4SS=tools/UE4SS_v3.0.1-1152-ge3ba1016
OUT=dist/KalanoroTogether
rm -rf dist
mkdir -p "$OUT/files"
cp dist-src/Install-KalanoroCoop.ps1 dist-src/Uninstall-KalanoroCoop.ps1 README.md LICENSE "$OUT/"
cp "$UE4SS/dwmapi.dll" "$OUT/files/"
cp -r "$UE4SS/ue4ss" "$OUT/files/"
cp -r src/KalanoroCoop "$OUT/files/ue4ss/Mods/KalanoroCoop"
cp -r src/KalanoroFix "$OUT/files/ue4ss/Mods/KalanoroFix"
rm -rf "$OUT/files/ue4ss/Mods/KalanoroCoop/logs"
python - "$OUT/files/ue4ss/Mods/mods.txt" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("; Built-in keybinds, do not move up!", "KalanoroCoop : 1\nKalanoroFix : 1\n\n; Built-in keybinds, do not move up!")
open(p, "w").write(s)
EOF
(cd dist && powershell -NoProfile -Command "Compress-Archive -Path KalanoroTogether -DestinationPath KalanoroTogether-$VERSION.zip -Force")
ls -la dist
