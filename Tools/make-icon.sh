#!/bin/zsh
# Rebuilds Resources/AppIcon.icns and docs/icon.png from Tools/make-icon/main.swift.
set -euo pipefail
cd "${0:A:h}/.."
WORK=$(mktemp -d)
swiftc -O -o "$WORK/make-icon" Tools/make-icon/main.swift
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns -o Resources/AppIcon.icns "$WORK/AppIcon.iconset"
cp "$WORK/AppIcon.iconset/icon_256x256@2x.png" docs/icon.png
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns and docs/icon.png"
