#!/bin/zsh
# launchd smoke: exercises the REAL LaunchAgent lifecycle on this machine.
# install → daemon status → server ensure → restart (bounce + re-ensure) →
# deliberate stop honored by auto-bootstrap → start → uninstall.
# Leaves no agent installed; uses a throwaway project + fixture-server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug"
WORK="$(mktemp -d /tmp/devctl-launchd-smoke.XXXXXX)"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
DEVCTL="$BIN/devctl"

fail() { echo "LAUNCHD-SMOKE FAIL: $1" >&2; cleanup; exit 1 }
pass() { echo "  ok: $1" }

cleanup() {
  "$DEVCTL" daemon uninstall > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "building..."
swift build --package-path "$ROOT" > /dev/null

if [[ -f "$HOME/Library/LaunchAgents/dev.quantizor.devctl.plist" ]]; then
  fail "a devctl LaunchAgent is already installed; refusing to clobber it"
fi

"$DEVCTL" daemon install > /dev/null || fail "daemon install"
pass "daemon install + hello"

"$DEVCTL" daemon status | grep -q "pid" || fail "daemon status shows no pid"
pass "daemon status"

cd "$PROJECT"
"$DEVCTL" register --name web --cmd "$BIN/fixture-server" --json > /dev/null
"$DEVCTL" ensure web --timeout 15 --json > /dev/null || fail "ensure never went healthy"
PID_BEFORE="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
pass "server up under launchd daemon (pid $PID_BEFORE)"

"$DEVCTL" daemon restart > /dev/null || fail "daemon restart"
PHASE="$("$DEVCTL" wait web --healthy --timeout 20 --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["phase"])')"
[[ "$PHASE" == "running" ]] || fail "server did not come back after restart (phase $PHASE)"
PID_AFTER="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
[[ "$PID_AFTER" != "$PID_BEFORE" ]] || fail "pid unchanged across restart; bounce did not happen"
pass "restart bounced and re-ensured (pid $PID_BEFORE -> $PID_AFTER)"

"$DEVCTL" daemon stop > /dev/null
sleep 2
set +e
STATUS_OUT="$("$DEVCTL" status web --json 2>&1)"
STATUS_EXIT=$?
set -e
[[ "$STATUS_EXIT" -ne 0 ]] || fail "status succeeded while deliberately stopped (auto-bootstrap ignored the intent)"
echo "$STATUS_OUT" | grep -q "deliberately stopped" || fail "missing deliberate-stop hint: $STATUS_OUT"
pass "deliberate stop honored by auto-bootstrap"

"$DEVCTL" daemon start > /dev/null || fail "daemon start"
"$DEVCTL" daemon status | grep -q "pid" || fail "daemon not back after start"
pass "daemon start"

# Auto-bootstrap: stop via bootout (simulating a dead daemon with no intent),
# then a plain status must resurrect it.
launchctl bootout "gui/$(id -u)/dev.quantizor.devctl" 2>/dev/null || true
sleep 1
"$DEVCTL" status --json > /dev/null || fail "auto-bootstrap did not resurrect the daemon"
"$DEVCTL" daemon status | grep -q "pid" || fail "daemon not resurrected"
pass "auto-bootstrap resurrects a dead daemon"

"$DEVCTL" daemon uninstall > /dev/null
[[ ! -f "$HOME/Library/LaunchAgents/dev.quantizor.devctl.plist" ]] || fail "plist survived uninstall"
pass "uninstall"

echo "LAUNCHD-SMOKE PASS"
