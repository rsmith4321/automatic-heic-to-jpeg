#!/bin/zsh
# Builds and runs Tools/selftest/main.swift against Sources/Core.swift.
set -euo pipefail
cd "${0:A:h}/.."
OUT=$(mktemp -d)
swiftc -swift-version 5 -o "$OUT/selftest" Sources/Core.swift Tools/selftest/main.swift
"$OUT/selftest"
rm -rf "$OUT"
