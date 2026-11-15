#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build/settings-ui
swiftc -swift-version 6 \
    Sources/TouchBarEnhancer/{Settings,ControlStripSettings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,MenuCommands,LyricsBackend,LyricsSettings,TextComponent}.swift \
    Tests/EnhancedBarSettingsSmoke.swift -o .build/enhanced-bar-settings-smoke
.build/enhanced-bar-settings-smoke
