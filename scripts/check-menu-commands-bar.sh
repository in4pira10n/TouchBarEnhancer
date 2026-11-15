#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
swiftc -swift-version 6 -I "$BIN_DIR/TouchBarBridge.build" \
    Sources/TouchBarEnhancer/{Settings,ControlStripSettings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,MenuCommands,LyricsBackend,LyricsSettings,TextComponent}.swift \
    Tests/MenuCommandsBarSmoke.swift "$BIN_DIR/TouchBarBridge.build/TouchBarBridge.m.o" -o .build/menu-commands-bar-smoke
bash scripts/run-app-check.sh .build/menu-commands-bar-smoke menu-commands
