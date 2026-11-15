#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build/lyrics-typography
swiftc -swift-version 6 \
    Sources/TouchBarEnhancer/{Settings,ControlStripSettings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,MenuCommands,LyricsBackend,LyricsSettings,TextComponent}.swift \
    Tests/LyricsTypographySmoke.swift -o .build/lyrics-typography-smoke
.build/lyrics-typography-smoke
