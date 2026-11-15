#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build
swiftc -swift-version 6 Sources/TouchBarEnhancer/LyricsBackend.swift Tests/LyricsBackendSmoke.swift -o .build/lyrics-backend-smoke
.build/lyrics-backend-smoke "$@"
