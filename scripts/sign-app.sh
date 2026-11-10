#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:?Usage: sign-app.sh /path/to/TouchBarEnhancer.app}"
IDENTITY="${TOUCHBAR_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$PROJECT_ROOT/.signing-identity.local" ]]; then
    IFS= read -r IDENTITY < "$PROJECT_ROOT/.signing-identity.local"
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
    printf '%s\n' 'A stable code-signing identity is required. Set TOUCHBAR_SIGNING_IDENTITY or .signing-identity.local; ad-hoc signing would invalidate Accessibility permissions.' >&2
    exit 1
fi
# Keep the bundle identifier and certificate-based designated requirement stable.
# Fail if the configured identity is unavailable; never fall back to ad-hoc.
codesign --force --timestamp=none --sign "$IDENTITY" "$APP_DIR"
codesign --verify --strict "$APP_DIR"
REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1)"
if [[ "$REQUIREMENT" == *'designated => cdhash '* ]]; then
    printf '%s\n' 'Refusing an update whose identity is tied to its binary hash.' >&2
    exit 1
fi
