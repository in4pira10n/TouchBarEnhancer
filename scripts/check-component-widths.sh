#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build
swiftc -swift-version 6 \
    Sources/TouchBarEnhancer/{Settings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,TextComponent}.swift \
    Tests/ComponentWidthsSmoke.swift -o .build/component-widths-smoke
.build/component-widths-smoke
