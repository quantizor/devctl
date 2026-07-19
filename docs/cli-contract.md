# devctl CLI contract

The JSON surface agents depend on. Every schema here is generated from the Codable types in `Sources/DevCtlKit` and locked by golden-file tests; changing a field is an API change and updates this document in the same commit. All timestamps are ISO-8601 UTC with milliseconds. Timeouts are seconds.

## Envelope

Success: the command's result object on stdout. Failure with `--json`: `{"ok": false, "error": {"code", "message", "hint"}}` on stdout; `hint` is the literal remediation command when one exists.

Stable `error.code` values: `config-invalid`, `daemon-unreachable`, `not-found`, `not-trusted`, `port-held`, `spawn-failed`, `usage`, `version-mismatch`. (Grows append-only.)

Exit codes: 0 ok · 1 operation failed (crash, timeout, conflict) · 2 usage · 3 daemon unreachable · 4 named server not found. Unnamed `status` in an unconfigured project exits 0 with `{"servers": []}`.

## ServerStatus (the core schema)

```jsonc
{
  "declaredPort": 3000,
  "healthcheck": "http",        // "http" | "tcp" | "none"
  "lastExit": { "at": "…", "code": 1, "signal": null },   // crashed only
  "lastHealthAt": "…",
  "logPath": "~/Library/Logs/devctl/myproj-a1b2c3d4/web/current.log",
  "observedPort": 3000,          // from post-healthy listen scan; may differ from declared
  "phase": "running",            // stopped|starting|running|unhealthy|stopping|crashed|failed
  "pid": 4242,
  "project": "/Users/me/code/myproj",
  "recentLogTail": ["…"],       // crashed/failed only
  "server": "web",
  "spawnError": { "errno": 2, "message": "…" },            // failed only
  "specStale": false,
  "uptimeSec": 123,
  "url": "http://myproj.localhost:3000/"
}
```

## Commands

Filled in per phase as each lands; golden tests reference the examples in this file.

- `devctl status [name] [--all] --json` → `{schemaVersion, servers: [ServerStatus]}` (single name → `{schemaVersion, server: ServerStatus}`)
- `devctl register --name N --cmd … [--port P] [--cwd D] [--write] --json` → `{registered: ServerStatus}`
- `devctl start|stop|restart <name> --json` → `{server: ServerStatus}`
- `devctl ensure <name> [--timeout 60] --json` → `{server: ServerStatus, reason?}` (fails fast on crashed/failed; `reason: "crashed"|"failed"|"timeout"`)
- `devctl wait <name> [--healthy|--stopped] [--timeout 60] --json` → `{server: ServerStatus, reason?}`
- `devctl up|down`, `devctl logs`, `devctl mark`, `devctl events`, `devctl why`, `devctl open`, `devctl trust`, `devctl config check`, `devctl doctor`, `devctl schema`, `devctl daemon …`: documented as each phase lands.
