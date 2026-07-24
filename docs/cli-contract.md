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

- `devctl status [name] --json` → `{servers: [ServerStatus]}`. Named lookup that matches nothing exits 4 (`not-found`); unnamed always exits 0.
- `devctl register --name N --cmd word --cmd word … [--port P] [--cwd D] --json` → `{server: ServerStatus}`. `--cmd` repeats per argv word and accepts dash-prefixed values.
- `devctl start|stop <name> --json` → `{server: ServerStatus}`. `start` returns at spawn with `phase: "starting"`; health promotion to `running` follows (use `wait`/`ensure` to block). `stop` on an already-stopped server exits 0.
- `devctl ensure <name> [--timeout 60] --json` → `{reason?, server}`. State matrix: healthy → no-op; starting → joins the in-flight attempt (single-flight, two concurrent ensures cannot double-spawn); unhealthy → no-op reporting the phase; stopped/crashed/failed → start and block until healthy. Fails fast the moment the phase turns crashed/failed. `reason: "crashed"|"failed"|"stopped"|"timeout"`; reason present ⇒ exit 1, with `lastExit`/`spawnError`/`recentLogTail` forensics in `server`.
- `devctl wait <name> [--healthy|--stopped] [--timeout 60] --json` → `{reason?, server}`. `--healthy` (default) rides through non-terminal transitions (another session's restart) and fails fast on crashed/failed/stopped; `--stopped` resolves on stopped/crashed/failed.
- Port pre-check on `start`/`ensure`: a declared port held by a managed server elsewhere → `port-held` naming that server and project; held by an unmanaged listener → `port-held` with pid + command when lsof can name it. Runs only when the target is not already up, so a server never conflicts with its own listener.
- Healthchecks: explicit `healthcheck` block wins; else a declared `port` implies a TCP probe; else healthy = alive past a 2s stabilization window. `ServerStatus.healthcheck` says which (`"http"|"tcp"|"none"`) so agents know when `running` is unverified. `unhealthyAfter` applies only after first-healthy: a slow boot stays `starting`.
- `devctl logs <name> [--follow] [--tail N] [--since 5m|ISO] [--since-mark <id>] [--grep RE] [--stream out|err|sys|mark] --json` → one `{at, stream, text}` object per line on stdout. `--grep` is the Swift Regex dialect. `--follow` polls incrementally (restart-safe). Structured lines are sanitized: ANSI/OSC escapes stripped, NULs removed, CR spinner rewrites collapsed to the final frame; timestamps are per-file monotonic.
- `devctl mark <name> <text> [--label L] --json` (or `--all <text>`) → `{marks: [{at, id, server}]}`. The id feeds `--since-mark` on `logs` and `events`, so no clock agreement is needed. Marks flow through the same append path as process output; ordering is exact.
- `devctl events [--all] [--since …] [--since-mark <id>] [--tail N] --json` → `{events: [{at, detail?, kind, project, server}]}` with kinds `started|stopped|crashed|failed|healthy|unhealthy|marked|registered|unregistered`. Scoped to the current project unless `--all`. This is the "what happened while I was compacted" answer.
- `devctl why <name> --json` → `{findings: [{server, phase, summary, evidence[]}], rootCause?}`. Walks `dependsOn` to the deepest broken dependency; evidence carries recent err-stream lines, declared-vs-observed port mismatches, and spec-drift notes.
- `devctl up [--only a,b] [--timeout 60] --json` → `{results: [{reason?, server}]}`. Wave-parallel in dependency order (Kahn waves); `--only` pulls in transitive dependencies; a wave with a failure stops the rollout (later waves depend on it); any `reason` ⇒ exit 1. `waitFor: "started"` on a server launches it without blocking on health; the default blocks until healthy. `devctl down --json` stops in reverse waves, always exit 0.
- `devctl trust --json` → approves the project's committed config. Trust is also recorded implicitly by an explicit `start`/`ensure`/`up` on a file-sourced server (the invocation is the approval); the SessionStart hook advertises only trusted projects. `status --json` carries `trusted` when project-scoped.
- `devctl open <name> [head]` → opens the server's URL in the default browser, or a named head of a multi-headed server. URLs derive as `http://<host>:<port>/` from the project `host` (default `<slug>.localhost`), overridable per server (`host` or `url` keys). A `heads` map (display name → URL) models one server fronting several surfaces (a Host-routing dev proxy); heads appear in `ServerStatus.heads`, the agent context block, and the app's row/detail menus.
- `devctl config check --json` → `{errors, host, servers, warnings}` from the daemon's own validator (cycles and unknown dependencies are errors; duplicate declared ports and unknown versions are warnings); errors ⇒ exit 1.
- `devctl doctor [--fix] --json` → `{findings: [{detail, kind, severity}]}`: daemon/launchd state, captured-PATH staleness, the host:port signature table with conflicts, unmanaged listeners on managed ports, and registry entries whose project path no longer exists (`--fix` prunes those).
- `devctl switch <branch> [--no-fetch] [--timeout 120]` → clean-tree guard (refuses dirty; never stashes), fetch, group down, `git switch` (remote-tracking fallback), then the project's `lifecycle.switch` playbook (argv arrays run sequentially from the project root; failures stop with `devctl up` as the resume hint), then group up. Playbooks live in devservers.json `lifecycle` and are agent-configurable.
- Config extras: project-level `icon` (project-relative path, per-server override) feeds Spotlight thumbnails; every server and head is indexed in Spotlight ("<project> <head>" opens the URL); `heads` and pins surface in the menu bar app.
- `devctl lock <resource> -- <command…> [--acquire-timeout 300] [--timeout 120]` → runs the command holding a project resource exclusively. Servers declaring the resource in their `locks` (devservers.json) are stopped first and re-ensured after (even on command failure); `ensure`/`start` of a declaring server is refused (`resource-locked`, naming the holder pid) while a live holder owns it; a dead holder auto-releases. Exit status is the command's. The mechanism for test harnesses whose private servers share mutable state (a local database) with a managed server.
- `devctl daemon install|uninstall [--purge]|start|stop|restart|status`: launchd lifecycle. `stop` drains and writes a deliberate-stop marker that auto-bootstrap honors; `restart` drains, kickstarts, and re-ensures what ran; `install` stages-and-renames the daemon binary and captures the login-shell PATH into the agent plist. Reboot recovery: the LaunchAgent runs at load, and starting a server records a resume-on-boot intent; a machine shutdown drains without clearing it, so the next login's daemon brings back every server that was up. A deliberate `devctl stop`/`down` clears the intent, so only those stay down.
- `devctl context`: the harness-agnostic session context: a fenced `<devctl-servers>` plain-text block (server phases, URLs, log paths, the ensure/wait/why/logs cheat-sheet) for the cwd's project. Silent (exit 0) when the project is unregistered or untrusted or the daemon is down; never bootstraps; never contains raw log lines or command strings.
- `devctl hook install [--harness claude|cursor] [--statusline]`: idempotently wires a session-start hook into the harness's settings (claude: SessionStart with matcher `startup|resume|clear|compact` in ~/.claude/settings.json, emitting `hookSpecificOutput.additionalContext`; cursor: sessionStart in ~/.cursor/hooks.json, emitting `{additional_context}`). Adding a harness: CONTRIBUTING.md.
- `devctl statusline`: reads harness statusline stdin JSON (workspace.current_dir or cwd), prints `web:3000 ok · api crashed` for the project, empty otherwise.
