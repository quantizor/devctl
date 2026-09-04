#!/usr/bin/env bash
# Verify ProcessType=Interactive on the live LaunchAgent and that managed
# servers are session leaders (pgid == pid) that do not share the daemon's
# jetsam coalition. Under the agent those servers are launchd jobs (ppid=1),
# so pids come from `directa status --all --json`, not pgrep -P. Full App Nap /
# QoS inheritance for setsid children needs root `taskinfo` or Instruments;
# this script stays userland and never rewrites the installed plist.
set -euo pipefail

LABEL="dev.quantizor.directa"
UID_NUM="$(id -u)"
SERVICE="gui/${UID_NUM}/${LABEL}"
PRINT_FILE="$(mktemp -t directa-launchctl-print)"

echo "== launchctl spawn type =="
if ! launchctl print "$SERVICE" >"$PRINT_FILE" 2>/dev/null; then
  echo "service $SERVICE not loaded; run: directa daemon install" >&2
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
echo "== managed servers (expect pgid==pid; pids from status, not pgrep -P) =="
ps -o pid,ppid,pgid,pri,nice,state,command -p "$DAEMON_PID"
if ! command -v directa >/dev/null; then
  echo "directa not on PATH; install the CLI and re-run" >&2
  exit 1
fi
STATUS_JSON="$(directa status --all --json --no-bootstrap)" || {
  echo "directa status --all failed; is the daemon reachable?" >&2
  exit 1
}
CHILDREN="$(python3 -c '
import json, sys
data = json.load(sys.stdin)
print(" ".join(str(s["pid"]) for s in data.get("servers", []) if s.get("pid")))
' <<<"$STATUS_JSON")"
if [[ -z "$CHILDREN" ]]; then
  echo "(no managed servers right now; ensure a server and re-run)"
  exit 0
fi

FAIL=0
for c in $CHILDREN; do
  line=$(ps -o pid=,ppid=,pgid=,pri=,nice=,state=,command= -p "$c") || {
    echo "  FAIL: pid $c from status is not running" >&2
    FAIL=1
    continue
  }
  echo "$line"
  pid=$(awk '{print $1}' <<<"$line")
  pgid=$(awk '{print $3}' <<<"$line")
  if [[ "$pid" != "$pgid" ]]; then
    echo "  FAIL: pid $pid is not a session leader (pgid=$pgid); group teardown needs pgid==pid" >&2
    FAIL=1
  fi
done

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

echo
echo "== jetsam coalitions (expect children not sharing the daemon) =="
python3 - "$DAEMON_PID" $CHILDREN <<'PY'
import ctypes, os, struct, sys
lib = ctypes.CDLL(None)
proc_pidinfo = lib.proc_pidinfo
proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
proc_pidinfo.restype = ctypes.c_int

def ids(pid):
    buf = ctypes.create_string_buffer(40)
    n = proc_pidinfo(int(pid), 20, 0, buf, 40)
    if n < 16:
        return None
    resource, jetsam = struct.unpack_from("<QQ", buf)
    return resource, jetsam

daemon = sys.argv[1]
d = ids(daemon)
print(f"daemon pid={daemon} resource={d[0] if d else '?'} jetsam={d[1] if d else '?'}")
shared_any = False
for pid in sys.argv[2:]:
    c = ids(pid)
    shared = d and c and c[1] == d[1]
    if shared:
        shared_any = True
    print(f"child  pid={pid} resource={c[0] if c else '?'} jetsam={c[1] if c else '?'} shared={bool(shared)}")
if shared_any:
    raise SystemExit("a managed child still shares the daemon jetsam coalition")
PY

echo
echo "OK: LaunchAgent is Interactive; managed servers are session leaders and do not share the daemon jetsam coalition."
echo "Root taskinfo / Instruments still needed to prove App Nap does not clamp setsid children;"
echo "without that evidence, keep ProcessType=Interactive on the agent and do not raise child QoS."
