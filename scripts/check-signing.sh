#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
ALTERNATE_BINARY="${1:?Usage: check-signing.sh /path/to/a/different/test-binary}"
FIXTURE_ROOT="$(mktemp -d "$PROJECT_ROOT/.build/signing-check.XXXXXX")"
FIRST_APP="$FIXTURE_ROOT/first.app"
SECOND_APP="$FIXTURE_ROOT/second.app"
cp -R dist/TouchBarEnhancer.app "$FIRST_APP"
cp -R dist/TouchBarEnhancer.app "$SECOND_APP"
cp .build/release/TouchBarEnhancer "$FIRST_APP/Contents/MacOS/TouchBarEnhancer"
cp "$ALTERNATE_BINARY" "$SECOND_APP/Contents/MacOS/TouchBarEnhancer"
if cmp -s "$FIRST_APP/Contents/MacOS/TouchBarEnhancer" "$SECOND_APP/Contents/MacOS/TouchBarEnhancer"; then
    printf '%s\n' 'Signing regression requires two different executables.' >&2
    exit 1
fi
bash scripts/sign-app.sh "$FIRST_APP"
bash scripts/sign-app.sh "$SECOND_APP"
FIRST_REQUIREMENT="$(codesign -d -r- "$FIRST_APP" 2>&1 | sed -n 's/^designated => //p')"
SECOND_REQUIREMENT="$(codesign -d -r- "$SECOND_APP" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$FIRST_REQUIREMENT" && "$FIRST_REQUIREMENT" == "$SECOND_REQUIREMENT" ]]
codesign --verify --strict -R "=$FIRST_REQUIREMENT" "$SECOND_APP"
printf '%s\n' 'Different executables retain the same certificate-based designated requirement.'
