#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$PROJECT_ROOT/dist/diagnostics/touchbar.png}"
mkdir -p "$(dirname "$OUTPUT_PATH")"
/usr/sbin/screencapture -b -x "$OUTPUT_PATH"
printf 'Touch Bar screenshot: %s\n' "$OUTPUT_PATH"
