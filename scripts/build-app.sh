#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_ROOT/dist/TouchBarEnhancer.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/TouchBarEnhancer" "$APP_DIR/Contents/MacOS/TouchBarEnhancer"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources/Images"
cp "$PROJECT_ROOT/Resources/Images/"*.png "$APP_DIR/Contents/Resources/Images/"
bash "$PROJECT_ROOT/scripts/sign-app.sh" "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
