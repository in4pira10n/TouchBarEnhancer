#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
TEST_BINARY="${1:?Usage: run-app-check.sh /path/to/test-binary [capture-name]}"
[[ -f "$TEST_BINARY" ]]
APP="$PROJECT_ROOT/dist/TouchBarEnhancer.app"
BIN="$APP/Contents/MacOS/TouchBarEnhancer"
CHECK_ROOT="$(mktemp -d "$PROJECT_ROOT/.build/app-check.XXXXXX")"
CAPTURE_PID=""
stop_app() {
    local app_pid
    app_pid="$(pgrep -f "^${BIN}$" || true)"
    if [[ -n "$app_pid" ]]; then
        kill -TERM "$app_pid"
        for attempt in {1..50}; do
            if ! kill -0 "$app_pid" 2>/dev/null; then return; fi
            sleep 0.1
        done
        printf '%s\n' 'The current app did not exit; refusing to overwrite a running executable.' >&2
        return 1
    fi
}
stop_app
cp "$BIN" "$CHECK_ROOT/production"
restore() {
    local check_status=$?
    if [[ -n "$CAPTURE_PID" ]]; then
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi
    stop_app
    cp "$CHECK_ROOT/production" "$BIN"
    bash scripts/sign-app.sh "$APP"
    open -g "$APP"
    return "$check_status"
}
trap restore EXIT
cp "$TEST_BINARY" "$BIN"
bash scripts/sign-app.sh "$APP"
if [[ -n "${2:-}" ]]; then
    CAPTURE_ROOT="$PROJECT_ROOT/.build/visual-checks/$2"
    mkdir -p "$CAPTURE_ROOT"
    # Screen capture belongs to the external harness, never the product app.
    (
        for frame in {0..119}; do
            /usr/sbin/screencapture -b -x "$CAPTURE_ROOT/$(printf '%03d' "$frame").png"
            sleep 0.08
        done
    ) &
    CAPTURE_PID=$!
fi
open -g -W --stdout "$CHECK_ROOT/stdout.log" --stderr "$CHECK_ROOT/stderr.log" "$APP"
cat "$CHECK_ROOT/stdout.log" "$CHECK_ROOT/stderr.log"
if rg -q 'Precondition failed|Fatal error|Assertion failed' "$CHECK_ROOT/stdout.log" "$CHECK_ROOT/stderr.log"; then
    exit 1
fi
# Launch Services does not return the app's assertion/exit status.
rg -q 'checks passed' "$CHECK_ROOT/stdout.log" "$CHECK_ROOT/stderr.log"
printf 'App check logs: %s\n' "$CHECK_ROOT"
