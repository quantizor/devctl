#!/bin/zsh
# Launch Services E2E for devctl:// (warm + cold open). Not part of default
# swift test; run before merging URL-scheme work. Requires a GUI session.
# Soft-fails the OSLog scrape when not on a tty unless DEVCTL_OSLOG_STRICT=1.
#
# Uses the LIVE default daemon socket (the menu bar app cannot see DEVCTL_SOCKET).
# Registers a throwaway server under a temp project, then tears it down.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug"
WORK="$(mktemp -d /tmp/devctl-deeplink-smoke.XXXXXX)"
PROJECT="$WORK/deeplink-fixture"
mkdir -p "$PROJECT"
SLUG="$(basename "$PROJECT")"
SERVER="web"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DEVCTL="$BIN/devctl"
# pgrep/pkill -f match their argument as a regex, where `.` is any character, so
# `devctl.app` would also match an unrelated `devctlXapp`. Escape every dot in
# the bundle path (including any in $ROOT) so the twin-count assertion counts
# exactly this build's copies. APP is set to the same path below.
APP_PATH="$ROOT/devctl.app"
APP_MATCH="${APP_PATH//./\\.}/Contents/MacOS/devctl-app"

fail() { echo "DEEPLINK SMOKE FAIL: $1" >&2; exit 1 }
pass() { echo "  ok: $1" }
warn() { echo "  warn: $1" >&2 }

phase_of() {
  "$DEVCTL" status "$SERVER" --project "$PROJECT" --json 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])' \
    2>/dev/null || echo missing
}

cleanup() {
  "$DEVCTL" stop "$SERVER" --project "$PROJECT" --json >/dev/null 2>&1 || true
  "$DEVCTL" unregister "$SERVER" --project "$PROJECT" --json >/dev/null 2>&1 || true
  [[ -n "${LOG_STREAM_PID:-}" ]] && kill "$LOG_STREAM_PID" 2>/dev/null || true
  # By bundle path, never by process name: the executable is devctl-app for the
  # copy built here AND for the one the user has in /Applications, and killing
  # theirs is not this script's business. `killall DevCtlApp` also matched
  # neither, so the copy this script launched used to outlive the run.
  pkill -f "$APP_MATCH" 2>/dev/null || true
  if [[ -d /Applications/devctl.app ]]; then
    "$LSREGISTER" -f /Applications/devctl.app >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STRICT_OSLOG="${DEVCTL_OSLOG_STRICT:-}"
if [[ -z "$STRICT_OSLOG" ]]; then
  if [[ -t 1 ]]; then STRICT_OSLOG=1; else STRICT_OSLOG=0; fi
fi

echo "building..."
swift build --package-path "$ROOT" > /dev/null
swift build --package-path "$ROOT" --product DevCtlApp > /dev/null
"$ROOT/scripts/make-app-bundle.sh" - debug
APP="$APP_PATH"
SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$APP/Contents/Info.plist")"
[[ "$SCHEME" == "devctl" ]] || fail "scheme was $SCHEME"
pass "Info.plist declares devctl://"

# Need a live daemon on the default socket (menu bar app path).
"$DEVCTL" daemon status >/dev/null 2>&1 || fail "devctld not running on the default socket; run: devctl daemon start"

cd "$PROJECT"
"$DEVCTL" register --name "$SERVER" --cmd "$BIN/fixture-server" --json > /dev/null
pass "fixture registered on live daemon"

"$LSREGISTER" -f "$APP"
pass "lsregister -f built app"

OSLOG_FILE="$WORK/oslog.txt"
/usr/bin/log stream --style compact --predicate 'subsystem == "dev.quantizor.devctl"' --level debug \
  >"$OSLOG_FILE" 2>/dev/null &
LOG_STREAM_PID=$!
sleep 1

open -a "$APP"
sleep 2

# A second copy of one bundle doubles the menu bar item, the poll and every
# crash notification. `open -n` asks for exactly that, and is what the DMG
# handoff asks for by name, so the newcomer has to stand down on its own. The
# count is path-scoped: an installed /Applications copy shares the bundle id and
# is allowed to keep running alongside this one.
count_app() { pgrep -f "$APP_MATCH" | wc -l | tr -d ' ' }
BEFORE_TWIN="$(count_app)"
[[ "$BEFORE_TWIN" == "1" ]] || fail "wanted 1 copy of $APP before the twin probe, saw $BEFORE_TWIN"
open -n "$APP"
sleep 4
AFTER_TWIN="$(count_app)"
[[ "$AFTER_TWIN" == "1" ]] || fail "open -n left $AFTER_TWIN copies of $APP running; the launch stand-down did not fire"
pass "open -n stood down; one copy still running"

open -a "$APP" "devctl://ensure/${SLUG}/${SERVER}"
PHASE=missing
for i in {1..40}; do
  PHASE="$(phase_of)"
  [[ "$PHASE" == "running" ]] && break
  sleep 0.5
done
[[ "$PHASE" == "running" ]] || fail "warm ensure left phase $PHASE"
pass "warm open ensure -> running"

# Path-scoped so an installed /Applications copy, which shares the executable
# name, is left alone: only the copy under test has to be gone for the next open
# to be a cold launch.
pkill -f "$APP_MATCH" 2>/dev/null || true
sleep 1
open -a "$APP" "devctl://stop/${SLUG}/${SERVER}"
PHASE=missing
for i in {1..40}; do
  PHASE="$(phase_of)"
  [[ "$PHASE" == "stopped" ]] && break
  sleep 0.5
done
[[ "$PHASE" == "stopped" ]] || fail "cold stop left phase $PHASE"
pass "cold open stop -> stopped"

sleep 1
kill "$LOG_STREAM_PID" 2>/dev/null || true
LOG_STREAM_PID=""
if rg -q 'deeplink|ensure|stop|dispatch' "$OSLOG_FILE"; then
  pass "oslog stream saw deeplink markers"
else
  if [[ "$STRICT_OSLOG" == "1" ]]; then
    fail "oslog stream empty (strict); file=$OSLOG_FILE"
  else
    warn "oslog stream empty (non-strict); skipping"
  fi
fi

echo "DEEPLINK SMOKE PASS"
