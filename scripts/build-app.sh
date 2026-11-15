#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
case "${1:-}" in
    "")
        swift build -c release
        BIN_DIR="$(swift build -c release --show-bin-path)"
        APP_BINARY="$BIN_DIR/TouchBarEnhancer"
        ;;
    --universal)
        swift build -c release --arch arm64
        ARM_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
        swift build -c release --arch x86_64
        INTEL_BIN_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"
        mkdir -p "$PROJECT_ROOT/.build/universal"
        APP_BINARY="$PROJECT_ROOT/.build/universal/TouchBarEnhancer"
        xcrun lipo -create "$ARM_BIN_DIR/TouchBarEnhancer" "$INTEL_BIN_DIR/TouchBarEnhancer" -output "$APP_BINARY"
        xcrun lipo "$APP_BINARY" -verify_arch arm64 x86_64
        ;;
    *)
        printf 'Usage: bash scripts/build-app.sh [--universal]\n' >&2
        exit 1
        ;;
esac
APP_DIR="$PROJECT_ROOT/dist/TouchBarEnhancer.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$APP_BINARY" "$APP_DIR/Contents/MacOS/TouchBarEnhancer"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources/Images"
cp "$PROJECT_ROOT/Resources/Images/"*.png "$APP_DIR/Contents/Resources/Images/"
bash "$PROJECT_ROOT/scripts/sign-app.sh" "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
