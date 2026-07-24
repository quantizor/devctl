#!/usr/bin/env bash
# Verify ProcessType=Interactive on the live LaunchAgent and that managed
# children are session leaders (pgid == pid). Full App Nap / QoS inheritance
# for setsid children needs root `taskinfo` or Instruments; this script stays
# userland and never rewrites the installed plist.
set -euo pipefail

LABEL="dev.quantizor.devctl"
UID_NUM="$(id -u)"
SERVICE="gui/${UID_NUM}/${LABEL}"
PRINT_FILE="$(mktemp -t devctl-launchctl-print)"

echo "== launchctl spawn type =="
if ! launchctl print "$SERVICE" >"$PRINT_FILE" 2>/dev/null; then
  echo "service $SERVICE not loaded; run: devctl daemon install" >&2
  exit 1
fi
grep -nE $'^\t(path|state|pid|spawn type|job state) =' "$PRINT_FILE" || true

SPAWN=$(grep -E 'spawn type =' "$PRINT_FILE" | head -1 || true)
echo "observed: ${SPAWN:-unknown}"
echo "$SPAWN" | grep -qi 'interactive' || {
  echo "expected spawn type = interactive (4); ProcessType may be missing from the plist" >&2
  exit 1
}

# The service summary line is a single tab then "pid = N" (not nested under xpc).
DAEMON_PID=$(awk -F' = ' '/^\tpid = /{print $2; exit}' "$PRINT_FILE")
if [[ -z "${DAEMON_PID:-}" || "$DAEMON_PID" == "0" ]]; then
  echo "daemon not running (could not parse pid from launchctl print)" >&2
  exit 1
fi
echo "daemon pid: $DAEMON_PID"

echo
echo "== daemon + direct children (expect children: pgid==pid) =="
ps -o pid,ppid,pgid,pri,nice,state,command -p "$DAEMON_PID"
CHILDREN=$(pgrep -P "$DAEMON_PID" || true)
if [[ -z "$CHILDREN" ]]; then
  echo "(no managed children right now; ensure a server and re-run)"
  exit 0
fi

FAIL=0
for c in $CHILDREN; do
  line=$(ps -o pid=,ppid=,pgid=,pri=,nice=,state=,command= -p "$c")
  echo "$line"
  pid=$(awk '{print $1}' <<<"$line")
  pgid=$(awk '{print $3}' <<<"$line")
  if [[ "$pid" != "$pgid" ]]; then
    echo "  FAIL: pid $pid is not a session leader (pgid=$pgid); group teardown assumes createSession" >&2
    FAIL=1
  fi
done

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

echo
echo "OK: LaunchAgent is Interactive; managed children are session leaders."
echo "Root taskinfo / Instruments still needed to prove App Nap does not clamp setsid children;"
echo "without that evidence, keep ProcessType=Interactive and do not raise child QoS."
