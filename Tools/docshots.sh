#!/bin/zsh
# Regenerates the README screenshots in docs/ (rendered off screen).
set -euo pipefail
cd "${0:A:h}/.."
WORK=$(mktemp -d)
swiftc -O -swift-version 5 -parse-as-library -D DOCSHOTS -o "$WORK/docshots" Sources/*.swift Tools/docshots/DocShots.swift
# Its own preferences domain, so your real settings are never read or changed.
defaults delete docshots >/dev/null 2>&1 || true
"$WORK/docshots" "$PWD/docs"
defaults delete docshots >/dev/null 2>&1 || true
rm -rf "$WORK"
