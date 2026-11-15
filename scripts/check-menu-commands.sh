#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build/menu-checks
swiftc -swift-version 6 \
    Sources/TouchBarEnhancer/{Settings,ControlStripSettings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,MenuCommands,LyricsBackend,LyricsSettings,TextComponent}.swift \
    Tests/MenuCommandsSmoke.swift -o .build/menu-commands-smoke
.build/menu-commands-smoke
