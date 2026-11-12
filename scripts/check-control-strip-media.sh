#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$BIN_DIR/TouchBarBridge.build" \
    Tests/ControlStripMediaSmoke.swift "$BIN_DIR/TouchBarBridge.build/TouchBarBridge.m.o" \
    -o .build/control-strip-media-smoke
.build/control-strip-media-smoke
