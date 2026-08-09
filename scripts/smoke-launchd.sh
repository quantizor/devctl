#!/bin/zsh
# launchd smoke: exercises the REAL LaunchAgent lifecycle on this machine.
# Uses the legacy home LaunchAgent path (--legacy) so it stays deterministic
# when /Applications/devctl.app is also present. For SMAppService, install from
# the app / Login Items on a GUI session separately.
# install → daemon status → server ensure → restart (bounce + re-ensure) →
# install-upgrade (bounce + re-ensure) → deliberate stop honored by
# auto-bootstrap → start → uninstall.
# Leaves no agent installed; uses a throwaway project + fixture-server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug"
WORK="$(mktemp -d /tmp/devctl-launchd-smoke.XXXXXX)"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
DEVCTL="$BIN/devctl"
LABEL="dev.quantizor.devctl"

fail() { echo "LAUNCHD-SMOKE FAIL: $1" >&2; cleanup; exit 1 }
pass() { echo "  ok: $1" }

cleanup() {
  "$DEVCTL" daemon uninstall > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "building..."
swift build --package-path "$ROOT" > /dev/null

if [[ -f "$HOME/Library/LaunchAgents/${LABEL}.plist" ]]; then
  fail "a legacy home LaunchAgent is already installed; refusing to clobber it"
fi
if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  fail "a ${LABEL} job is already bootstrapped; refusing to clobber it"
fi

"$DEVCTL" daemon install --legacy > /dev/null || fail "daemon install --legacy"
pass "daemon install + hello (legacy home LaunchAgent)"

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

# Upgrade-in-place: install again while the server is up must re-ensure it,
# same contract as restart (this is what `make install` hits).
PID_PRE_UPGRADE="$PID_AFTER"
"$DEVCTL" daemon install --legacy > /dev/null || fail "daemon install upgrade"
PHASE="$("$DEVCTL" wait web --healthy --timeout 20 --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["phase"])')"
[[ "$PHASE" == "running" ]] || fail "server did not come back after install upgrade (phase $PHASE)"
PID_POST_UPGRADE="$("$DEVCTL" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
[[ "$PID_POST_UPGRADE" != "$PID_PRE_UPGRADE" ]] || fail "pid unchanged across install upgrade; bounce did not happen"
pass "install upgrade bounced and re-ensured (pid $PID_PRE_UPGRADE -> $PID_POST_UPGRADE)"

"$DEVCTL" daemon stop > /dev/null
sleep 2
set +e
STATUS_OUT="$("$DEVCTL" status web --json 2>&1)"
STATUS_EXIT=$?
set -e
[[ "$STATUS_EXIT" -ne 0 ]] || fail "status succeeded while deliberately stopped (auto-bootstrap ignored the intent)"
echo "$STATUS_OUT" | grep -q "deliberately stopped" || fail "missing deliberate-stop hint: $STATUS_OUT"
pass "deliberate stop honored by auto-bootstrap"

"$DEVCTL" daemon start --legacy > /dev/null || fail "daemon start"
"$DEVCTL" daemon status | grep -q "pid" || fail "daemon not back after start"
pass "daemon start"

# Auto-bootstrap: stop via bootout (simulating a dead daemon with no intent),
# then a plain status must resurrect it.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
sleep 1
"$DEVCTL" status --json > /dev/null || fail "auto-bootstrap did not resurrect the daemon"
"$DEVCTL" daemon status | grep -q "pid" || fail "daemon not resurrected"
pass "auto-bootstrap resurrects a dead daemon"

# Deprecated alias: `daemon uninstall` still tears the agent down and warns on
# stderr, keeping stdout clean for --json consumers. (This removes the agent.)
ALIAS_ERR="$WORK/alias.err"
set +e
ALIAS_OUT="$("$DEVCTL" daemon uninstall --json 2>"$ALIAS_ERR")"
set -e
grep -q "deprecated" "$ALIAS_ERR" || fail "daemon uninstall did not warn on stderr (got: $(cat "$ALIAS_ERR"))"
if echo "$ALIAS_OUT" | grep -q "deprecated"; then
  fail "deprecation notice leaked into stdout: $ALIAS_OUT"
fi
[[ ! -f "$HOME/Library/LaunchAgents/${LABEL}.plist" ]] || fail "plist survived the deprecated alias"
pass "deprecated 'daemon uninstall' warns on stderr, stdout clean, plist gone"

# The new one-verb uninstall: --agent-only removes just the agent (what the cask
# calls on every upgrade) and reports a stable JSON shape. Full uninstall's hook
# and CLI removal is covered by unit tests, which do not touch the real machine.
"$DEVCTL" daemon install --legacy > /dev/null || fail "reinstall before the agent-only test"
AGENT_ONLY_OUT="$("$DEVCTL" uninstall --agent-only --json 2>/dev/null)"
echo "$AGENT_ONLY_OUT" | /usr/bin/python3 -c \
  'import json,sys; d=json.load(sys.stdin); assert d["agentOnly"] is True and d["purged"] is False, d' \
  || fail "uninstall --agent-only JSON shape: $AGENT_ONLY_OUT"
[[ ! -f "$HOME/Library/LaunchAgents/${LABEL}.plist" ]] || fail "plist survived uninstall --agent-only"
pass "uninstall --agent-only removed the agent (hooks and data untouched)"

echo "LAUNCHD-SMOKE PASS"
