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

# Wait until the daemon ANSWERS OVER THE SOCKET, never until the socket file
# merely exists. Two traps this avoids, both of which report ready for the wrong
# reason: a daemon killed with -9 leaves its socket file behind, so a file test
# passes instantly against a dead listener; and `daemon status` falls back to
# launchd state and exits 0 without connecting, so it answers even when nothing
# is listening. Requiring daemonVersion in the payload forces a real round trip.
# Fails loudly rather than letting a later command report a confusing error.
await_daemon() {
  local label="$1"
  for i in {1..100}; do
    "$BIN/devctl" daemon status --json 2>/dev/null | grep -q '"reachable":true' && return 0
    sleep 0.1
  done
  fail "daemon never answered over $DEVCTL_SOCKET ($label); it may be alive without having bound the socket"
}

cleanup() {
  [[ -n "${DAEMON_PID:-}" ]] && kill -9 "$DAEMON_PID" 2>/dev/null || true
  [[ -n "${CHILD_PID:-}" ]] && kill -9 "-$CHILD_PID" 2>/dev/null || true
  # Grandchildren escape the process group on purpose (that is what the teardown
  # assertions exercise), so a group kill leaves them behind. Reap them by pid.
  for stray in ${STRAY_PIDS:-}; do kill -9 "$stray" 2>/dev/null || true; done
  # Orphans from a mid-smoke abort can hold fixed listen ports across reruns.
  pkill -f "$BIN/fixture-server" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "building..."
swift build --package-path "$ROOT" > /dev/null

echo "starting daemon..."
"$BIN/devctld" --foreground --socket "$DEVCTL_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" &
DAEMON_PID=$!
await_daemon "first boot"
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
TCP_PORT=$((39000 + (RANDOM % 500)))
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
P3_DB=$((41000 + (RANDOM % 500)))
P3_WEB=$((P3_DB + 1))
cat > "$PROJECT3/devservers.json" <<CFG
{
  "version": 1,
  "host": "smoketest.localhost",
  "servers": {
    "db": { "command": ["$BIN/fixture-server", "--listen-tcp", "$P3_DB"], "port": $P3_DB },
    "web": { "command": ["$BIN/fixture-server", "--listen-tcp", "$P3_WEB"], "dependsOn": ["db"], "heads": { "admin": "/admin" }, "port": $P3_WEB }
  }
}
CFG
# restart the smoke daemon (killed above) for the project phase
"$BIN/devctld" --foreground --socket "$DEVCTL_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" &
DAEMON_PID=$!
await_daemon "project phase restart"
cd "$PROJECT3"

"$DEVCTL" config check --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["errors"]==[], d; assert d["host"]=="smoketest.localhost", d' || fail "config check"
pass "config check validates devservers.json"

set +e
UP_OUT="$("$DEVCTL" up --timeout 15 --json 2>/tmp/devctl-smoke-up.err)"
UP_EXIT=$?
set -e
[[ "$UP_EXIT" -eq 0 ]] || fail "up exit $UP_EXIT: $UP_OUT $(cat /tmp/devctl-smoke-up.err 2>/dev/null)"
echo "$UP_OUT" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(r.get("reason") is None for r in d["results"]), d; assert len(d["results"])==2, d' || fail "up did not bring both servers healthy: $UP_OUT"
pass "up brings the project healthy in dependency order"

"$DEVCTL" status web --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['servers'][0]; assert d['url']=='http://smoketest.localhost:$P3_WEB/', d" || fail "derived url wrong"
pass "host signature url derived"

# A root-relative head must resolve against the server's own base, not serialize
# as `//:port/admin`, which reads as a URL everywhere it lands and works nowhere.
"$DEVCTL" status web --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['servers'][0]; assert d['heads']['admin']=='http://smoketest.localhost:$P3_WEB/admin', d" || fail "relative head did not resolve against the server base"
pass "relative head resolves against the server base"

# The same mistake on a server with no base to resolve against is caught while it
# is still cheap, rather than shipping a broken URL to every heads consumer.
BADHEAD="$WORK/badhead"
mkdir -p "$BADHEAD"
cat > "$BADHEAD/devservers.json" <<'CFG'
{ "version": 1, "servers": { "web": { "command": ["true"], "heads": { "admin": "/admin" } } } }
CFG
set +e
"$DEVCTL" config check --project "$BADHEAD" --json > "$WORK/badhead.json" 2>/dev/null
BADHEAD_EXIT=$?
set -e
[[ "$BADHEAD_EXIT" -ne 0 ]] || fail "config check accepted an unresolvable head"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/badhead.json'));assert any('head' in e and 'resolve it against' in e for e in d['errors']), d" || fail "config check did not explain the unresolvable head"
pass "config check rejects an unresolvable head"

# devservers.json is routinely gitignored per machine, so the daemon has to be
# able to write one back. What it writes must pass its own validator.
RECOVER="$WORK/recover"
mkdir -p "$RECOVER"
R_PORT=$((42500 + (RANDOM % 300)))
"$DEVCTL" register --project "$RECOVER" --name recovered --cmd "$BIN/fixture-server" --cmd --listen-tcp --cmd "$R_PORT" --port "$R_PORT" --json > /dev/null || fail "register for recovery"
"$DEVCTL" config init --project "$RECOVER" --json > "$WORK/init.json" || fail "config init"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/init.json'));assert d['written'] is True, d; assert d['check']['servers']==['recovered'], d; assert '\n  ' in d['content'], 'file should be indented'" || fail "config init result"
[[ -f "$RECOVER/devservers.json" ]] || fail "config init wrote no file"
"$DEVCTL" config check --project "$RECOVER" --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); assert d['errors']==[], d; assert d['servers']==['recovered'], d" || fail "recovered config does not validate"
pass "config init writes a file its own validator accepts"

set +e
"$DEVCTL" config init --project "$RECOVER" --json > "$WORK/init2.json" 2>/dev/null
INIT2_EXIT=$?
set -e
[[ "$INIT2_EXIT" -ne 0 ]] || fail "config init clobbered an existing file"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/init2.json'));assert d['error']['code']=='already-exists', d" || fail "config init did not refuse with already-exists"
"$DEVCTL" config init --project "$RECOVER" --force --json > /dev/null || fail "config init --force"
pass "config init refuses to clobber without --force"

# register --write must add one entry and leave the rest of the file alone.
"$DEVCTL" register --project "$RECOVER" --name second --cmd "$BIN/fixture-server" --port $((R_PORT + 1)) --write --json > /dev/null || fail "register --write"
/usr/bin/python3 -c "import json;d=json.load(open('$RECOVER/devservers.json'));assert sorted(d['servers'])==['recovered','second'], d" || fail "register --write lost an entry"
pass "register --write appends without disturbing the rest"

"$DEVCTL" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("trusted") is True, d' || fail "project not trusted after up"
pass "trust recorded by explicit up"

"$DEVCTL" down --json > /dev/null
"$DEVCTL" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(s["phase"]=="stopped" for s in d["servers"]), d' || fail "down left servers running"
pass "down stops the project"

# Derived error facts + agent context safety: a crasher writes distinctively
# tagged stderr, then dies. devctl must count those lines (its own arithmetic)
# and inject a `devctl why` command, while never leaking the raw child bytes
# into the context block the session hook feeds an agent.
PROJECT_CRASH="$WORK/project-crash"
mkdir -p "$PROJECT_CRASH"
cat > "$PROJECT_CRASH/devservers.json" <<CFG
{
  "version": 1,
  "host": "crash.localhost",
  "servers": {
    "flaky": { "command": ["$BIN/fixture-server", "--err-lines", "3", "--exit-after", "0.4", "--code", "1"] }
  }
}
CFG
cd "$PROJECT_CRASH"
set +e
"$DEVCTL" ensure flaky --timeout 5 --json > /dev/null 2>&1
set -e
# Poll for the terminal phase; the fixture exits shortly after start.
for i in {1..50}; do
  CRASH_PHASE="$("$DEVCTL" status flaky --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
  [[ "$CRASH_PHASE" == "crashed" ]] && break
  sleep 0.1
done
[[ "$CRASH_PHASE" == "crashed" ]] || fail "crasher never reached crashed (was $CRASH_PHASE)"
"$DEVCTL" status flaky --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["servers"][0]; s=d.get("errorSummary"); assert s and s["count"]>=3, d' || fail "errorSummary did not count the stderr lines"
pass "status carries a derived error count"

CONTEXT_OUT="$("$DEVCTL" context)"
echo "$CONTEXT_OUT" | grep -q "run: devctl why flaky --json" || fail "context omitted the why recommendation: $CONTEXT_OUT"
echo "$CONTEXT_OUT" | grep -q "error line" || fail "context omitted the error count line: $CONTEXT_OUT"
if echo "$CONTEXT_OUT" | grep -q "FIXTURE-ERR-TOKEN"; then
  fail "SECURITY: raw child stderr leaked into the agent context block"
fi
pass "context recommends devctl why and never leaks raw child output"
cd "$PROJECT3"

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

# Stopping a server to get exclusive access to something it holds is the heavy
# way there. The hint says so in human mode and stays out of --json stdout,
# which carries the machine-readable `locks` array instead.
"$DEVCTL" stop db 2>"$WORK/stop.err" >/dev/null || fail "stop db"
grep -q "devctl lock data --" "$WORK/stop.err" || fail "stop did not hint toward lock: $(cat "$WORK/stop.err")"
"$DEVCTL" ensure db --timeout 15 --json > /dev/null || fail "re-ensure db"
"$DEVCTL" stop db --json > "$WORK/stop.json" 2>/dev/null || fail "stop db --json"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/stop.json'));assert d['server']['locks']==['data'], d" || fail "stop --json lost the locks array"
grep -q "hint:" "$WORK/stop.json" && fail "stop --json leaked the hint into stdout"
pass "stop hints toward lock in human mode and keeps --json stdout clean"

"$DEVCTL" down --json > /dev/null

# Deep-link and lock --no-pause coverage stay below; worktree coexistence first.

# Sibling worktree coexistence: shared git common-dir auto-rebinds the linked
# checkout onto a free port and a worktree-* host while main keeps the declared
# origin. Fixture listens on {port} so materialization is load-bearing.
WT_ROOT="$WORK/wt-coexist"
mkdir -p "$WT_ROOT/main"
cd "$WT_ROOT/main"
git init -b main >/dev/null
git config user.email "smoke@devctl.test"
git config user.name "devctl-smoke"
echo ok > README
git add README
git commit -m init >/dev/null
mkdir -p "$WT_ROOT/worktrees"
git worktree add -b review "$WT_ROOT/worktrees/review" >/dev/null
WT_PORT=$((52000 + (RANDOM % 1000)))
cat > "$WT_ROOT/main/devservers.json" <<CFG
{
  "host": "smoke.localhost",
  "servers": {
    "web": {
      "command": ["$BIN/fixture-server", "--listen-tcp", "{port}"],
      "healthcheck": { "type": "tcp", "port": $WT_PORT },
      "port": $WT_PORT,
      "url": "http://smoke.localhost:$WT_PORT/"
    }
  },
  "version": 1
}
CFG
cp "$WT_ROOT/main/devservers.json" "$WT_ROOT/worktrees/review/devservers.json"
cd "$WT_ROOT/main"
set +e
MAIN_ENSURE="$("$DEVCTL" ensure web --timeout 15 --json 2>/tmp/devctl-smoke-main-ensure.err)"
MAIN_ENSURE_EXIT=$?
set -e
[[ "$MAIN_ENSURE_EXIT" -eq 0 ]] || fail "main worktree ensure exit $MAIN_ENSURE_EXIT: $MAIN_ENSURE $(cat /tmp/devctl-smoke-main-ensure.err 2>/dev/null)"
echo "$MAIN_ENSURE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['server']; assert d['phase']=='running', d; assert d.get('effectivePort')==$WT_PORT, d; assert d['url']=='http://smoke.localhost:$WT_PORT/', d; assert d.get('portConflict') is None, d" || fail "main worktree ensure: $MAIN_ENSURE"
pass "main checkout keeps declared host and port"
cd "$WT_ROOT/worktrees/review"
set +e
WT_ENSURE="$("$DEVCTL" ensure web --timeout 15 --json 2>/tmp/devctl-smoke-wt-ensure.err)"
WT_ENSURE_EXIT=$?
set -e
[[ "$WT_ENSURE_EXIT" -eq 0 ]] || fail "linked worktree ensure exit $WT_ENSURE_EXIT: $WT_ENSURE $(cat /tmp/devctl-smoke-wt-ensure.err 2>/dev/null)"
echo "$WT_ENSURE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['server']; assert d['phase']=='running', d; assert d.get('effectivePort')!=$WT_PORT, d; assert d.get('portConflict',{}).get('state')=='rebound', d; assert 'worktree-review.smoke.localhost' in (d.get('url') or ''), d" || fail "linked worktree ensure: $WT_ENSURE"
pass "linked worktree auto-rebinds with worktree-* host"
CTX="$("$DEVCTL" context)"
echo "$CTX" | grep -q "worktree-review.smoke.localhost" || fail "context omitted worktree URL: $CTX"
pass "worktree context advertises ephemeral URL"
"$DEVCTL" stop web --json > /dev/null
cd "$WT_ROOT/main"
"$DEVCTL" stop web --json > /dev/null
"$DEVCTL" unregister web --json > /dev/null || true
cd "$WT_ROOT/worktrees/review"
"$DEVCTL" unregister web --json > /dev/null || true
pass "worktree coexistence cleaned up"

# lock --no-pause: holder stays up while the lock is held.
cd "$PROJECT3"
"$DEVCTL" up --timeout 15 --json > /dev/null || fail "up before --no-pause"
NO_PAUSE_STATUS="$WORK/no-pause-status.json"
set +e
"$DEVCTL" lock data --no-pause -- "$DEVCTL" status db --json > "$NO_PAUSE_STATUS" 2>"$WORK/no-pause.err"
NO_PAUSE_EXIT=$?
set -e
[[ "$NO_PAUSE_EXIT" -eq 0 ]] || fail "lock --no-pause failed ($NO_PAUSE_EXIT): $(head -c 400 "$NO_PAUSE_STATUS" 2>/dev/null) $(cat "$WORK/no-pause.err" 2>/dev/null)"
# Drop any human pause lines lock might print; the status JSON is the last object.
NO_PAUSE_PHASE="$(/usr/bin/python3 -c 'import json,sys; lines=open(sys.argv[1]).read().splitlines();
objs=[json.loads(l) for l in lines if l.strip().startswith("{")];
assert objs, open(sys.argv[1]).read();
print(objs[-1]["servers"][0]["phase"])' "$NO_PAUSE_STATUS")"
[[ "$NO_PAUSE_PHASE" == "running" ]] || fail "lock --no-pause paused db (phase $NO_PAUSE_PHASE; out=$(cat "$NO_PAUSE_STATUS"))"
pass "lock --no-pause leaves declarer running"
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
