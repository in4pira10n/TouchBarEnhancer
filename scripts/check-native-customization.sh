#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build
clang -fobjc-arc -c Tests/NativeCustomizationBridge.m -o .build/native-customization-check.o
swiftc -swift-version 6 -import-objc-header Tests/NativeCustomizationBridge.h \
    Sources/TouchBarEnhancer/{Settings,ControlStripSettings,AppBar,AppsPane,ChatGPTAdapter,ChatGPTPane,ChatGPTStrip,QuickPhrases,ScrollingComponents,KeyboardButtons,TextComponent}.swift \
    Tests/NativeCustomizationSmoke.swift .build/native-customization-check.o -o .build/native-customization-smoke
.build/native-customization-smoke
