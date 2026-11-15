#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$BIN_DIR/TouchBarBridge.build" \
    Sources/TouchBarEnhancer/LyricsBackend.swift Tests/LyricsMediaSmoke.swift \
    "$BIN_DIR/TouchBarBridge.build/TouchBarBridge.m.o" -o .build/lyrics-media-smoke
.build/lyrics-media-smoke "$@"
