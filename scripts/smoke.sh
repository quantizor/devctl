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
  # Grandchildren escape the process group on purpose (that is what the teardown
  # assertions exercise), so a group kill leaves them behind. Reap them by pid.
  for stray in ${STRAY_PIDS:-}; do kill -9 "$stray" 2>/dev/null || true; done
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
GRANDCHILD_PID="$(grep grandchild "$SPOOL" | head -1 | awk '{print $NF}')"
pass "spool capturing output (grandchild pid $GRANDCHILD_PID)"

"$DEVCTL" wait web --healthy --timeout 10 --json > /dev/null || fail "wait --healthy did not resolve"
PHASE="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
[[ "$PHASE" == "running" ]] || fail "status phase was $PHASE, wanted running"
pass "wait --healthy resolved; status reports running"

# ensure is idempotent: same pid back, no reason.
ENSURE_PID="$("$DEVCTL" ensure web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["pid"])')"
[[ "$ENSURE_PID" == "$CHILD_PID" ]] || fail "ensure respawned a healthy server ($CHILD_PID -> $ENSURE_PID)"
pass "ensure no-op on healthy server"

# Cross-project port conflict: a second project declaring the same port must be refused.
PROJECT2="$WORK/project2"
mkdir -p "$PROJECT2"
TCP_PORT=39871
"$DEVCTL" register --name tcp --cmd "$BIN/fixture-server" --cmd --listen-tcp --cmd "$TCP_PORT" --port "$TCP_PORT" --json > /dev/null
"$DEVCTL" ensure tcp --timeout 10 --json > /dev/null || fail "tcp fixture never became healthy"
pass "tcp healthcheck (port $TCP_PORT)"
cd "$PROJECT2"
"$DEVCTL" register --name rival --cmd /bin/sleep --cmd 30 --port "$TCP_PORT" --json > /dev/null
set +e
RIVAL_OUT="$("$DEVCTL" ensure rival --timeout 5 --json 2>/dev/null)"
RIVAL_EXIT=$?
set -e
[[ "$RIVAL_EXIT" -ne 0 ]] || fail "rival ensure should have failed on held port"
echo "$RIVAL_OUT" | grep -q "port-held" || fail "rival error was not port-held: $RIVAL_OUT"
pass "cross-project port conflict refused (port-held)"
cd "$PROJECT"
"$DEVCTL" stop tcp --json > /dev/null

# Phase 3: marks, since-mark queries, events, why.
MARK_ID="$("$DEVCTL" mark web "smoke correlation point" --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["marks"][0]["id"])')"
[[ -n "$MARK_ID" ]] || fail "mark returned no id"
sleep 0.5
AFTER_COUNT="$("$DEVCTL" logs web --since-mark "$MARK_ID" --stream out --json | wc -l | tr -d ' ')"
[[ "$AFTER_COUNT" -ge 1 ]] || fail "no out lines after mark"
"$DEVCTL" logs web --grep "heartbeat" --tail 3 --json > /dev/null || fail "grep query failed"
pass "mark + since-mark + grep queries ($AFTER_COUNT lines since mark)"

"$DEVCTL" events --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(e["kind"]=="started" for e in d["events"]), d' || fail "events feed missing started"
pass "events feed records lifecycle"

WHY_OUT="$("$DEVCTL" why web)"
echo "$WHY_OUT" | grep -q "running and healthy" || fail "why did not report healthy: $WHY_OUT"
pass "why reports healthy chain"

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
# The child writes its raw spool directly; the structured log resumes when a
# daemon returns. Survival is judged on the raw spool.
RAW_SPOOL="$(dirname "$SPOOL")/out.spool"
BEFORE="$(wc -l < "$RAW_SPOOL")"
sleep 1
AFTER="$(wc -l < "$RAW_SPOOL")"
[[ "$AFTER" -gt "$BEFORE" ]] || fail "raw spool stopped growing after daemon death"
pass "child survived daemon kill and kept logging ($BEFORE -> $AFTER raw lines)"
STRAY_PIDS="${STRAY_PIDS:-} $(grep grandchild "$RAW_SPOOL" | tail -1 | awk '{print $NF}')"
kill -9 "-$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

# Phase 5: a real devservers.json project with dependencies, trust, up/down.
PROJECT3="$WORK/project3"
mkdir -p "$PROJECT3"
cat > "$PROJECT3/devservers.json" <<CFG
{
  "version": 1,
  "host": "smoketest.localhost",
  "servers": {
    "db": { "command": ["$BIN/fixture-server", "--listen-tcp", "39901"], "port": 39901 },
    "web": { "command": ["$BIN/fixture-server", "--listen-tcp", "39902"], "dependsOn": ["db"], "port": 39902 }
  }
}
CFG
# restart the smoke daemon (killed above) for the project phase
"$BIN/devctld" --foreground --socket "$DEVCTL_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" &
DAEMON_PID=$!
for i in {1..50}; do [[ -S "$DEVCTL_SOCKET" ]] && break; sleep 0.1; done
cd "$PROJECT3"

"$DEVCTL" config check --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["errors"]==[], d; assert d["host"]=="smoketest.localhost", d' || fail "config check"
pass "config check validates devservers.json"

UP_OUT="$("$DEVCTL" up --timeout 15 --json)"
echo "$UP_OUT" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(r.get("reason") is None for r in d["results"]), d; assert len(d["results"])==2, d' || fail "up did not bring both servers healthy: $UP_OUT"
pass "up brings the project healthy in dependency order"

"$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["servers"][0]; assert d["url"]=="http://smoketest.localhost:39902/", d' || fail "derived url wrong"
pass "host signature url derived"

"$DEVCTL" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("trusted") is True, d' || fail "project not trusted after up"
pass "trust recorded by explicit up"

"$DEVCTL" down --json > /dev/null
"$DEVCTL" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(s["phase"]=="stopped" for s in d["servers"]), d' || fail "down left servers running"
pass "down stops the project"

# Resource locks: db declares the resource; lock pauses it, refuses ensure, resumes after.
/usr/bin/python3 - "$PROJECT3/devservers.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["servers"]["db"]["locks"] = ["data"]
json.dump(cfg, open(p, "w"))
PY
"$DEVCTL" up --timeout 15 --json > /dev/null || fail "up before lock test"
LOCK_OUT="$("$DEVCTL" lock data -- sh -c "sleep 1; $DEVCTL status db --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)[\"servers\"][0]; assert d[\"phase\"]==\"stopped\", d[\"phase\"]' && $DEVCTL ensure db --timeout 3 --json > /dev/null 2>&1 && exit 44 || exit 0")"
LOCK_EXIT=$?
[[ "$LOCK_EXIT" -eq 0 ]] || fail "lock run failed ($LOCK_EXIT): db not paused or ensure not refused"
PHASE_AFTER="$("$DEVCTL" wait db --healthy --timeout 15 --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["phase"])')"
[[ "$PHASE_AFTER" == "running" ]] || fail "db did not resume after lock (phase $PHASE_AFTER)"
pass "resource lock pauses holder, refuses ensure, resumes after"
"$DEVCTL" down --json > /dev/null

# Deep links: print URL + dispatch via x-url (no Launch Services).
cd "$PROJECT"
SLUG="$(basename "$PROJECT")"
LINK_URL="$("$DEVCTL" link ensure web)"
[[ "$LINK_URL" == "devctl://ensure/${SLUG}/web" ]] || fail "link ensure printed '$LINK_URL'"
pass "link prints canonical URL ($LINK_URL)"
"$DEVCTL" x-url "$LINK_URL" --json > /dev/null || fail "x-url ensure failed"
"$DEVCTL" wait web --healthy --timeout 15 --json > /dev/null || fail "x-url ensure never healthy"
pass "x-url ensure"
"$DEVCTL" x-url "devctl://stop/${SLUG}/web" --json > /dev/null || fail "x-url stop failed"
PHASE_STOP="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
[[ "$PHASE_STOP" == "stopped" ]] || fail "x-url stop left phase $PHASE_STOP"
pass "x-url stop"
"$DEVCTL" x-url "devctl://why/${SLUG}/web" --json > /dev/null || fail "x-url why failed"
pass "x-url why"
set +e
BAD_OUT="$("$DEVCTL" x-url 'devctl://ensure/no-such-slug/web' --json 2>/dev/null)"
BAD_EXIT=$?
set -e
[[ "$BAD_EXIT" -ne 0 ]] || fail "x-url unknown slug should fail"
echo "$BAD_OUT" | grep -Eq 'not-found|"ok":false' || fail "x-url bad slug envelope: $BAD_OUT"
pass "x-url rejects unknown slug"

# Bundle advertises the custom URL scheme and ships CLI + daemon for first-run.
"$ROOT/scripts/make-app-bundle.sh" - debug
SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$ROOT/devctl.app/Contents/Info.plist")"
[[ "$SCHEME" == "devctl" ]] || fail "assembled Info.plist scheme was '$SCHEME'"
pass "assembled app declares CFBundleURLSchemes=devctl"
ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/devctl.app/Contents/Info.plist")"
[[ "$ICON" == "AppIcon" ]] || fail "assembled Info.plist CFBundleIconFile was '$ICON'"
[[ -f "$ROOT/devctl.app/Contents/Resources/AppIcon.icns" ]] || fail "bundle missing Resources/AppIcon.icns"
pass "assembled app ships AppIcon.icns"
DISPLAY="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ROOT/devctl.app/Contents/Info.plist")"
[[ "$DISPLAY" == "quantizor/devctl" ]] || fail "assembled Info.plist CFBundleDisplayName was '$DISPLAY'"
pass "assembled app display name is quantizor/devctl"
ROLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleTypeRole' "$ROOT/devctl.app/Contents/Info.plist")"
[[ "$ROLE" == "Editor" ]] || fail "assembled Info.plist CFBundleTypeRole was '$ROLE'"
pass "assembled app URL type role is Editor"
[[ -x "$ROOT/devctl.app/Contents/Resources/devctl" ]] || fail "bundle missing Resources/devctl"
[[ -x "$ROOT/devctl.app/Contents/Resources/devctld" ]] || fail "bundle missing Resources/devctld"
pass "assembled app ships CLI and daemon in Resources"
[[ -x "$ROOT/devctl.app/Contents/Helpers/devctld" ]] || fail "bundle missing Helpers/devctld"
AGENT_PLIST="$ROOT/devctl.app/Contents/Library/LaunchAgents/dev.quantizor.devctl.plist"
[[ -f "$AGENT_PLIST" ]] || fail "bundle missing Library/LaunchAgents/dev.quantizor.devctl.plist"
BUNDLE_PROG="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT_PLIST")"
[[ "$BUNDLE_PROG" == "Contents/Helpers/devctld" ]] || fail "BundleProgram was '$BUNDLE_PROG'"
# launchd caps ExitTimeOut at 60 and logs a complaint above it.
AGENT_EXIT_TIMEOUT="$(/usr/libexec/PlistBuddy -c 'Print :ExitTimeOut' "$AGENT_PLIST")"
[[ "$AGENT_EXIT_TIMEOUT" -le 60 ]] || fail "ExitTimeOut was '$AGENT_EXIT_TIMEOUT'; launchd caps it at 60"
pass "assembled app ships Helpers/devctld + in-bundle LaunchAgent"

kill -9 "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""

echo "SMOKE PASS"
