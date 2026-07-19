#!/bin/zsh
# Phase 1 smoke gate: real devctld + real CLI + real fixture-server.
# Asserts: registration, start, status, spool capture, whole-group death on stop,
# and child survival across a daemon kill (spool-fd capture, no SIGPIPE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug"
WORK="$(mktemp -d /tmp/devctl-smoke.XXXXXX)"
export DEVCTL_SOCKET="$WORK/daemon.sock"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"

fail() { echo "SMOKE FAIL: $1" >&2; exit 1 }
pass() { echo "  ok: $1" }

cleanup() {
  [[ -n "${DAEMON_PID:-}" ]] && kill -9 "$DAEMON_PID" 2>/dev/null || true
  [[ -n "${CHILD_PID:-}" ]] && kill -9 "-$CHILD_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "building..."
swift build --package-path "$ROOT" > /dev/null

echo "starting daemon..."
"$BIN/devctld" --foreground --socket "$DEVCTL_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" &
DAEMON_PID=$!
for i in {1..50}; do [[ -S "$DEVCTL_SOCKET" ]] && break; sleep 0.1; done
[[ -S "$DEVCTL_SOCKET" ]] || fail "daemon socket never appeared"
pass "daemon up (pid $DAEMON_PID)"

cd "$PROJECT"
DEVCTL="$BIN/devctl"

"$DEVCTL" register --name web --cmd "$BIN/fixture-server" --cmd --spawn-grandchild --json > /dev/null
pass "register"

START_JSON="$("$DEVCTL" start web --json)"
CHILD_PID="$(echo "$START_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["pid"])')"
[[ "$CHILD_PID" -gt 0 ]] || fail "no pid from start"
pass "start (child pid $CHILD_PID)"

sleep 1
SPOOL="$(echo "$START_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["logPath"])')"
grep -q heartbeat "$SPOOL" || fail "spool has no heartbeats"
grep -q grandchild "$SPOOL" || fail "fixture never spawned its grandchild"
GRANDCHILD_PID="$(grep grandchild "$SPOOL" | head -1 | awk '{print $3}')"
pass "spool capturing output (grandchild pid $GRANDCHILD_PID)"

PHASE="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
[[ "$PHASE" == "running" ]] || fail "status phase was $PHASE, wanted running"
pass "status reports running"

"$DEVCTL" stop web --json > /dev/null
kill -0 "$CHILD_PID" 2>/dev/null && fail "child survived stop"
kill -0 "$GRANDCHILD_PID" 2>/dev/null && fail "grandchild survived stop: group-kill failed"
pass "stop killed the whole process group"

# Daemon-death survival: start again, kill the daemon, the child must keep
# running and keep writing to its spool (no SIGPIPE from dead pipes).
"$DEVCTL" start web --json > /dev/null
CHILD_PID="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
kill -9 "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""
sleep 1
kill -0 "$CHILD_PID" 2>/dev/null || fail "child died with the daemon"
BEFORE="$(wc -l < "$SPOOL")"
sleep 1
AFTER="$(wc -l < "$SPOOL")"
[[ "$AFTER" -gt "$BEFORE" ]] || fail "spool stopped growing after daemon death"
pass "child survived daemon kill and kept logging ($BEFORE -> $AFTER lines)"
kill -9 "-$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

echo "SMOKE PASS"
