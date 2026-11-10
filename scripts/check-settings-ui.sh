#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build
swiftc -swift-version 6 \
    Sources/TouchBarEnhancer/{Settings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,TextComponent}.swift \
    Tests/SettingsUISmoke.swift -o .build/settings-ui-smoke
.build/settings-ui-smoke
