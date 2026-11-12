#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
swiftc -swift-version 6 -I "$BIN_DIR/TouchBarBridge.build" \
    Sources/TouchBarEnhancer/{Settings,ControlStripSettings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,TextComponent,ApplicationMenus,AppDelegate}.swift \
    Tests/ControlStripSmoke.swift "$BIN_DIR/TouchBarBridge.build/TouchBarBridge.m.o" -o .build/control-strip-smoke
bash scripts/run-app-check.sh .build/control-strip-smoke control-strip
