> Ratified plan snapshot (2026-07-18), kept as the design rationale record. The
> living documents are CLAUDE.md (map + invariants) and docs/cli-contract.md
> (the JSON surface). Known deviations from this plan, chosen during the build:
> push subscriptions were replaced by incremental polling everywhere (CLI
> --follow and the app; restart-safe, no reconnect machinery), logs.follow /
> status.subscribe never shipped as wire methods, and the crash verb landed as
> forensics inside `status` plus `devctl why` rather than `devctl crash`. The
> `register --write` back-to-file option and the automatic CLAUDE.md stanza
> offer did not ship (backlogged); resource locks (`devctl lock`) shipped
> beyond the plan.

# devctl: macOS menu bar command center for dev servers

## Context

Coding agents lose track of their dev servers across compaction and session boundaries: they forget a server is running, spawn duplicates, tail dead logs, or flail at ports they no longer own. devctl fixes this with a persistent supervisor that outlives any session, a CLI designed for agents as the primary consumer, and a menu bar app for Evan. New greenfield project at `~/code/devctl`, all Swift, personal-first (structured for later OSS release; signing/notarization/tap deferred). Name chosen by Evan: devctl. This plan was hardened by three adversarial passes (one inline, two red-team agents: agent-consumer lens and macOS-systems lens); their findings are folded in throughout.

## Decisions (locked with Evan)

- Architecture: launchd-managed background daemon owns all server processes; CLI and menu bar app are thin clients over a unix domain socket. Servers survive UI restarts; everything works headless.
- Stack: all Swift, single SPM package, buildable and testable entirely from the command line (no Xcode).
- Registration: committed per-project `devservers.json` + ad-hoc `devctl register`; daemon keeps a machine-local registry persisting across reboots.
- v1 features: `ensure` (idempotent start), `wait --healthy`, structured logs + markers, crash forensics, Claude Code SessionStart hook, click-to-open server URLs, unique `*.localhost` signatures per project, and the understanding layer (`devctl why` diagnosis, unified `events` feed, dashboard timeline, crash notifications).
- Scope: multi-server projects, group ops (`up`/`down`) with dependency ordering.
- UI: menu dropdown + full dashboard window (log viewer, config editing, health history, port map).

## Toolchain (verified current, 2026-07)

Swift 6.3 (6.3.3 latest), Swift 6 language mode with strict concurrency. Dependencies, exactly two: `apple/swift-argument-parser` 1.8.0 (CLI only) and `swiftlang/swift-subprocess` pinned exact 0.5.x (daemon only; pre-1.0, isolated behind an internal `ProcessLauncher` protocol with a posix_spawn fallback documented). Tests use Swift Testing via `swift test`. App minimum target macOS 14 (`@Observable`).

## Package layout (single SPM package at ~/code/devctl)

- `Sources/DevCtlKit/`: shared core library and the unit-test target of record. Model types (ServerSpec, ServerStatus, ProjectConfig, HealthCheck), devservers.json codec + validation + dependency topo sort, wire protocol messages + NDJSON codec, `DaemonClient` actor (POSIX socket transport used by both CLI and app), log line format + query engine, on-disk path constants + atomic-write helpers.
- `Sources/DevCtlDaemonCore/`: daemon logic as a testable library. `ServerSupervisor` actor (spawn/teardown/spool tailer), health probes + state machine, persistent registry + state store, `LogStore` actor (append/rotate/tail-ring/subscriptions), `ControlServer` (NWListener + router).
- `Sources/devctld/`: thin executable main. Runs identically under launchd and `--foreground` (tests, debugging).
- `Sources/devctl/`: CLI executable (swift-argument-parser).
- `Sources/DevCtlApp/`: SwiftUI MenuBarExtra app, pure DaemonClient consumer, default-MainActor module isolation.
- `Sources/fixture-server/`: test helper executable (TCP/HTTP responder with `--exit-after`, `--spawn-grandchild`, `--ignore-sigterm`, `--emit-binary`, `--flood` modes).
- `Makefile` + `scripts/make-app-bundle.sh` + `scripts/install.sh`, `Resources/` (Info.plist with LSUIElement, launchd plist template, AppIcon.icns).

## On-disk layout

- `~/Library/Application Support/devctl/`: `daemon.sock` (0600; fallback `/tmp/devctl-$UID/daemon.sock` near the 104-byte sun_path limit; `DEVCTL_SOCKET` overrides; actual path advertised in `daemon.info`), `daemon.lock` (flock held for daemon lifetime; the single-instance mutex: the lock holder alone may unlink and rebind the socket, so stale-socket takeover cannot race), `registry.json`, `state.json`, `stopped.intent` (marker written by deliberate shutdown; auto-bootstrap honors it), `bin/devctld` (stable path the launchd plist points at), `daemon.log` (self-rotated 10 MB × 5; the launchd redirect catches pre-init stderr only).
- State durability: atomic writes are temp + fsync + rename. On load-parse failure, rename the file to `.corrupt-<timestamp>`, log a `sys` event, continue with empty state; corruption is never fatal (a parse crash under KeepAlive would loop forever).
- `~/Library/Logs/devctl/<project-slug>-<hash8>/<server>/`: `current.log` + rotated `.1`-`.5`, `spool.log` (raw child output, truncated per run), `health.json` (ring of last 100 health transitions).
- `~/Library/LaunchAgents/dev.quantizor.devctl.plist`.
- Server identity: `serverID = "<project-canonical-path>::<name>"`, where canonical = realpath (symlinks resolved, on-disk case) computed identically in CLI and daemon, so `~/code` symlinks and `/tmp` vs `/private/tmp` cannot mint duplicate identities.

## Config model: devservers.json (committed at project root)

```json
{
  "version": 1,
  "host": "myproj.localhost",
  "servers": {
    "api": {
      "command": ["bun", "run", "dev:api"],
      "cwd": "packages/api",
      "env": { "PORT": "8787" },
      "healthcheck": { "type": "http", "url": "http://127.0.0.1:8787/healthz", "intervalMs": 2000, "timeoutMs": 1500, "healthyAfter": 1, "unhealthyAfter": 3 },
      "port": 8787
    },
    "web": {
      "command": ["bun", "run", "dev"],
      "dependsOn": ["api"],
      "port": 3000,
      "url": "http://myproj.localhost:3000/",
      "waitFor": "healthy"
    }
  }
}
```

- `command` is an argv array (no shell); `"shell": true` escape hatch runs via `/bin/zsh -lc` for nvm/mise-style setups, tradeoff documented. `cwd` is relative to project root (monorepo packages need it).
- Host signature (Evan's isolation requirement): project-level `host` defaults to `<project-slug>.localhost`; per-server subdomain overrides allowed (`api.myproj.localhost`). Each server's `url` derives as `http://<host>:<port>/` unless set explicitly. The registry enforces machine-wide uniqueness of host:port signatures; registering a claimed pair errors naming the holder. Unique origins keep browser cookies/storage/service workers isolated per project. Resolution caveat handled: browsers resolve `*.localhost` to loopback themselves, CLI tools and the system resolver do not reliably, so daemon healthchecks connect to 127.0.0.1 with the configured `Host` header, and the agent cheat-sheet says the same for curl. Backlog: devctl-managed reverse proxy on :80/:443 for port-free URLs.
- Healthcheck defaults: explicit block wins; else a declared `port` implies a TCP probe on it; else healthy = process alive past a 2s stabilization window. Status JSON carries `healthcheck: "http"|"tcp"|"none"` so agents know when "healthy" is unverified. `unhealthyAfter` applies only after first-healthy; exiting during `starting` is a crash, not a flap.
- Validation: unknown keys warn, dependency cycles hard-error, signature/port collisions error at registration and start (below). Malformed config → `config-invalid` error carrying file, line, and failing key; `devctl config check` validates read-side (same validator the daemon uses on write).
- `devctl register` writes ad-hoc entries into the machine registry only (optional `--write` back to devservers.json). Daemon re-reads devservers.json lazily per project-scoped request, mtime-cached; no fsnotify in v1. A spec hash is recorded at spawn; when the file drifts under a running server, status/ensure report `specStale: true` with a restart hint.
- Trust-on-first-use: the daemon acts on a project's committed config only after one explicit approval (`devctl trust`, or implicit on the first human/agent-invoked `start`/`ensure` in that project, recorded in the registry). Until then the SessionStart hook does not advertise the project, so a freshly cloned malicious repo cannot push its commands into agent context unprompted.

## Wire protocol

NDJSON over the unix socket (one JSON object per line; JSONEncoder without prettyPrinted never emits interior newlines; debuggable with `nc -U`). Request `{id, method, params}` → response `{id, ok, result|error}`; server-push `{event, sub, params}` frames for `logs.follow` and `status.subscribe` (replay/since supported). Daemon greets each connection with a `hello` frame carrying protocol + daemon version; on major mismatch the CLI aborts with `error.code: "version-mismatch"` naming both versions and the exact fix (`devctl daemon restart`). Methods: `daemon.info/shutdown`, `project.status/trust/writeConfig/check`, `server.register/unregister/start/stop/restart/ensure/wait/status/open/why`, `logs.query/mark/follow`, `events.query/subscribe`, `group.up/down`. Timestamps ISO-8601 UTC with ms.

`ServerStatus`, the schema agents live on: `{server, project, phase: stopped|starting|running|unhealthy|stopping|crashed|failed, pid?, declaredPort?, observedPort?, url?, healthcheck, logPath, lastExit?, spawnError?, specStale?, lastHealthAt?, uptimeSec?, recentLogTail?}`. `failed` (spawn never succeeded: ENOENT/EACCES, with `spawnError {errno, message}` and the daemon's effective PATH in the hint) is distinct from `crashed` (ran, then died, with `lastExit`). `observedPort` comes from the daemon's post-healthy listen scan; Vite/Next silently auto-increment, so declared-vs-observed mismatch is surfaced rather than hidden.

## Daemon internals

- Actor-per-subsystem, strict concurrency; per-server operations serialize through a single-flight state machine: concurrent `ensure`/`start` calls join the in-flight attempt and share its outcome (two agent sessions ensuring the same server cannot double-spawn; integration-tested), `stop` during `starting` cancels then stops.
- Ensure state matrix: stopped/crashed/failed → start and await outcome; starting → join; running+healthy → no-op; unhealthy → no-op reporting `"health": "unhealthy"`; stopping → await stop, then start. Before spawning, ensure/start pre-check the declared port and host:port signature against the registry: held by a managed server in another project (the two-worktrees case) → fail naming that serverID with the choice to use it or stop it there; held by an unmanaged pid → fail with pid + command (doctor's squatter logic lives in the start path, not only in doctor).
- Output capture is file-based, never pipes: child stdout/err are duped onto the per-run `spool.log` fd at spawn. The daemon tails the spool (kqueue EVFILT_VNODE) into the structured log: line-split, lossy UTF-8 with NUL stripping, `\r` spinner-rewrite handling, ANSI/OSC escape stripping (raw escapes are a terminal/context injection surface), 16 KB partial-line cap, timestamps monotonic-clamped per file (an NTP step or wake-time sync cannot break the sorted invariant the since-search needs). A spool fd survives daemon death, so servers never take SIGPIPE from a daemon restart or crash.
- Spawn via swift-subprocess with `createSession = true`; stop = SIGTERM to the process group, 7s grace, SIGKILL to the group, so npm→node→esbuild trees die together (a grandchild calling setsid escapes; documented, `proc_listchildpids` sweep backlogged). Foundation `Process` rejected: no group control, deadlock-prone pipes.
- Daemon lifecycle semantics (stated truthfully, the red-team centerpiece):
  - Graceful exit (`daemon.shutdown`, uninstall, upgrade, `daemon restart`): drain-stop all servers through the normal teardown path first. Restart/upgrade records the set of running servers and re-ensures them after the new daemon is up, so "servers bounce, then come back" is the contract. Shutdown writes `stopped.intent`; exits 0.
  - `KeepAlive = {SuccessfulExit: false}`: crashes relaunch, deliberate shutdown stays down. CLI auto-bootstrap honors `stopped.intent` (cleared by `daemon install`/explicit start).
  - Crash recovery: on launch, servers recorded running whose pid is gone (kill(pid,0) + proc_pidinfo start-time against pid reuse) → `crashed(daemon-restart)`; servers whose pid is alive (orphans, still logging safely into their spool) → group-killed, marked, and restarted if their recorded phase was running. Never adopted silently; pipe-less capture means nothing died or wedged in the interim. True re-adoption without the bounce is backlogged (orphan exit codes are unknowable for non-children).
  - Upgrades stage the new binary and `rename(2)` it into place, never cp over the running Mach-O (overwriting a signed running binary gets it SIGKILLed mid-install).
- Health monitor per running server: HTTP 2xx or TCP connect probes (127.0.0.1 + Host header), consecutive-threshold state machine, transitions pushed to subscribers and appended to health.json. Sleep-aware: system power notifications (IORegisterForSystemPower) pause probes across sleep and reset failure counters with a wake grace window, so lid-open does not flap every server unhealthy. Timeouts use ContinuousClock; uptime derives from the recorded start wall-timestamp.
- ControlServer: NWListener with `requiredLocalEndpoint = .unix(path:)`; single-instancing via the flock above; one Task per request so a slow `server.wait` never blocks the connection. Known cosmetic NECP log noise on unix listeners (Apple DTS-confirmed); not suppressed. `setrlimit` raises maxfiles to the hard limit at startup (launchd jobs default to a 256 soft limit, verified; a dozen servers plus subscribers approaches it) and doctor reports fd usage.
- `logs.follow` subscribers get bounded queues; on overflow drop oldest and emit one `sys` "N lines dropped" frame. Disk append is the reliable path; live follow is best-effort by contract.

## Log design

Structured line format: `ISO8601\t<stream>\t<payload>` with streams `out`, `err`, `sys` (start/stop/exit/rotation/drop events), `mark`. Markers flow through the same append path as tailed output, so ordering against process output is exact; each carries the requester's label (client pid or `--label`) so an agent can tell its own actions from a concurrent session's. Rotation at 10 MB × 5 files, line-boundary only. `--since` binary-searches the timestamp prefix within each file (safe under the monotonic clamp) and skips whole files by their last line; `--grep` is a daemon-side Swift Regex scan streamed back (dialect documented in `--help` and `schema`). `status`/`ensure` always print `logPath`; agents may also grep the files directly, both paths supported on purpose.

## CLI surface (agents are the primary consumer)

Every command has `--json` (stable schemas carrying `schemaVersion`, generated from the same Codable types the daemon uses so there is no hand-maintained schema to drift, and locked by golden-file tests treated as API). JSON to stdout in success and failure: failures emit `{ok: false, error: {code, message, hint}}` where `code` is a stable string agents branch on (`version-mismatch`, `config-invalid`, `port-held`, `not-trusted`, `spawn-failed`, `daemon-unreachable`, ...) and `hint` is the literal remediation command. Exit codes stay coarse: 0 ok, 1 operation failed, 2 usage, 3 daemon unreachable, 4 named server not found. Unnamed `status` in an unconfigured project exits 0 with `{servers: []}` and a hint, never 4. Timeouts are seconds.

- `devctl status [name] [--all]`: phase, pid, declared/observed port, url, health, specStale, logPath; crashed/failed shows lastExit/spawnError + recentLogTail (the forensics live here; there is no separate crash verb, which read as destructive).
- `devctl ensure <name> [--timeout 60]`: per the state matrix; always prints {pid, observedPort, url, logPath, phase}. Fails fast the moment phase turns crashed/failed with `reason: "crashed"|"failed"|"timeout"` plus forensics in the JSON.
- `devctl wait <name> [--healthy|--stopped] [--timeout 60]`: rides through non-terminal transitions (another session's restart), fails immediately on crashed/failed with `reason`; `--stopped` closes the down-then-rebuild loop.
- `devctl up [--only a,b]` / `devctl down`: topo-ordered, independent branches in parallel, honoring `waitFor`. `stop`/`down` on already-stopped targets exit 0 (idempotent, matching ensure).
- `devctl start|stop|restart <name>`; `devctl open <name>` (opens the server URL in the default browser); `devctl register|unregister [--stale]`; `devctl trust`; `devctl config check`.
- `devctl logs <name> [--follow] [--tail N] [--since 5m|ISO] [--since-mark <id>] [--grep RE] [--stream out|err|sys|mark]`.
- `devctl mark <name|--all> "text" [--label L]`: returns `{id, at}` so `--since-mark` needs no clock agreement.
- `devctl doctor [--fix]`: daemon health, socket, launchd state, fd usage, captured-PATH staleness, signature table with squatters, stale registry entries (project paths that no longer exist) and orphaned log dirs; `--fix` prunes on confirmation.
- `devctl why <name>`: the understanding layer. A rule-based diagnosis over data the daemon already holds: current phase and health trend, last crash/spawn error, the most recent err-stream lines, port/signature conflicts, spec drift, and a `dependsOn` walk to find root cause ("web is unhealthy: healthcheck failing since 14:02, last err ECONNREFUSED api:8787; api crashed 14:01 exit 1"). `--json` returns the finding chain so agents act on it directly.
- `devctl events [--since 5m|--since-mark <id>] [--follow]`: the unified event stream (starts, stops, crashes, health transitions, marks, config changes) as structured records; the agent's "what happened while I was compacted" question answered without log parsing. Backed by the same `sys`/`mark`/health data, exposed as one feed.
- `devctl schema`; `devctl daemon install|uninstall [--purge]|status|restart`.
- Project resolution: nearest ancestor with `devservers.json` → git root → cwd, `--project <path>` everywhere, all canonicalized. Concurrent auto-bootstrap from parallel sessions treats "already bootstrapped" as success and converges on the socket poll.

## Agent integration (the amnesia fix; hook facts verified against current docs)

- `devctl hook install` merges (never clobbers, idempotent) a SessionStart hook into user settings with matcher `startup|resume|clear|compact`; `compact` fires right after auto/manual compaction, exactly when agents forget. Hook command `devctl status --hook`: `--no-bootstrap`, hard 300ms self-timeout, always exits 0, silent when the project is unregistered/untrusted or the daemon is down (one stderr line pointing at doctor). Emits `hookSpecificOutput.additionalContext` with per-server name/phase/url/logPath plus the ensure→wait→logs cheat-sheet, inside clearly delimited fences, length-capped, never raw log lines or command strings (prompt-injection hygiene; server output is attacker-influenceable).
- `devctl hook install --statusline` offers a statusline snippet (stdin carries `workspace.current_dir`): `web:3000 ok · api:8787 crashed`.
- Discovery: `register --write` and `hook install` offer a one-line CLAUDE.md/AGENTS.md stanza for the project, so an agent that has never heard of devctl learns to prefer `devctl ensure` over `npm run dev`.
- `docs/cli-contract.md` in the repo enumerates every command's JSON schema and per-phase behavior; it is the contract the golden tests enforce and lands before the code that implements it.

## launchd

Plist: `RunAtLoad`, `KeepAlive = {SuccessfulExit: false}`, `ProcessType=Interactive` (App Nap/QoS claim for own-session children unverified; confirm during Phase 4), stdout/err redirect for pre-init only, `EnvironmentVariables.PATH` captured from `/bin/zsh -lc 'echo $PATH'` at install (surfaced in `daemon.info` and doctor since it goes stale after Homebrew migrations). No socket activation: the daemon must be resident whenever servers run, KeepAlive covers crashes, one code path keeps foreground/test runs identical. Install flow: stage binary → rename into place → render plist → `launchctl bootout gui/$UID/...` (ignore failure) → `launchctl bootstrap gui/$UID <plist>` → poll socket for hello. Restart = drain + `launchctl kickstart -k` + re-ensure. (Current launchctl 2.0 vocabulary.)

## Menu bar app + dashboard

- `MenuBarExtra` with `.window` style (menu style cannot render dots/rows/buttons). `LSUIElement=true`, unsandboxed (sandboxed apps cannot reach unix sockets outside their container; non-MAS by design). Launch-at-login toggle via `SMAppService.mainApp`.
- No SwiftUI `Settings` scene (documented-broken from MenuBarExtra on Tahoe); dashboard and settings are a plain `Window` scene via `openWindow` + `NSApp.activate`.
- One `@Observable @MainActor DaemonModel` owning a DaemonClient; `status.subscribe` mirrors pushes; reconnect loop with backoff so daemon restarts are invisible to the UI.
- Ambient state: the menu bar glyph itself reports aggregate health, quiet when everything is green, badged when anything crashed or failed; the app subscribes to the event stream and posts a macOS notification on crash with a "View logs" action (UserNotifications lives in the app since the daemon has no bundle).
- Dropdown: per-project sections, rows = status dot + name + host:port + start/stop/restart; clicking a row opens the server's URL in the default browser (Evan's request); footer: Open Dashboard, Quit (app only).
- Dashboard: NavigationSplitView; virtualized log viewer over `logs.follow` with replay, search, jump-to-marker; config editor writing through `project.writeConfig` with optimistic concurrency (write carries the hash of the loaded version; daemon rejects on mismatch with reload-and-retry, so an IDE edit is never silently clobbered; v1 warns that writes normalize formatting); a timeline lane per server built from the event stream (colored phase spans with marker pins, replacing a bare sparkline); port/signature map (declared vs observed, squatter pids).
- Project aesthetic (recorded in CLAUDE.md at bootstrap): a quiet instrument panel. Monochrome SF Symbols glyph, tally-light status dots with a subtle breathing animation on `starting`, dense but calm typography, no chrome; state changes register visibly but never shout.

## Build pipeline (no Xcode ever)

`make build` = `swift build -c release`; `make app` = checked-in `scripts/make-app-bundle.sh` assembling `devctl.app/Contents/{MacOS,Info.plist,Resources}` + ad-hoc `codesign --force --sign -`; `make install` = binaries to `~/.local/bin`, app to /Applications, `devctl daemon install`. `SIGN_IDENTITY` variable upgrades to Developer ID + notarization at OSS-release time. Tuist/XcodeGen/Swift Bundler evaluated and rejected (Xcode dependency or unclear release cadence); the script is the documentation.

## Implementation phases

1. Tracer bullet: DevCtlKit models + NDJSON codec + POSIX DaemonClient; `devctld --foreground` on NWListener (flock single-instancing from day one) serving info/register/start/status/stop; supervisor with spool-file capture, tailer, group-kill; CLI register/start/status/stop --json. Gate: start fixture-server, verify pid + logs flowing, stop, verify the whole group died; kill the daemon mid-run, verify the child kept running and logging into its spool.
2. Agent ergonomics: healthchecks + defaults, ensure state matrix + single-flight, wait with fail-fast reasons, failed-vs-crashed forensics, port/signature pre-checks, error envelope + `docs/cli-contract.md` + golden tests.
3. Logs + events: structured LogStore, rotation, monotonic clamp, since/since-mark/tail/grep, follow subscription with bounded queues, mark with ids/labels, ANSI stripping; the unified `events` feed and `devctl why` (both derive from LogStore sys/mark data + health transitions).
4. launchd: daemon install/uninstall/restart with drain + re-ensure, stage-and-rename upgrade, intent marker, auto-bootstrap, PATH capture, crash recovery incl. orphan handling, setrlimit, sleep/wake pause. Verify the ProcessType claim.
5. Projects: devservers.json loading + validation + trust, host signatures, DAG, up/down, specStale.
6. Menu bar app: bundle pipeline, dropdown with click-to-open, status.subscribe, ambient icon state, crash notifications, login item.
7. Dashboard: log viewer + markers, config editing with optimistic concurrency, event timeline lanes, signature map. `devctl hook install` (can land any time after phase 2).

Project hygiene at bootstrap: CLAUDE.md (symlinked AGENTS.md) with codebase map + build/test commands; BACKLOG.md seeded with: orphan re-adoption without the bounce, reverse proxy for port-free `*.localhost` URLs, setsid-grandchild sweep via proc_listchildpids, MenuBarExtraAccess if presentation quirks bite, Developer ID signing + notarization + Homebrew tap, ProcessType=Interactive verification, field-level config editing to preserve file formatting. Unit branch coverage target >80% on DevCtlKit/DevCtlDaemonCore.

## Verification

- `swift test` (<30s): config validation/topo sort/trust, protocol codec round-trips + golden schemas incl. error envelopes, log parse + clamp + since binary-search + rotation, health state machine, ensure state matrix + single-flight (mocked ProcessLauncher), spool tailer against synthetic files (binary junk, NULs, ANSI, torn lines).
- Component tests against fixture-server: group-kill of grandchildren, SIGKILL escalation, crash forensics, spawn-failure (bogus command → `failed` + spawnError), flood + slow-subscriber drop behavior.
- Integration suite (serialized): real `devctld --foreground` on a temp socket: register→trust→ensure→wait→mark→logs since-mark→external kill→crash status→concurrent double-ensure→port-conflict from a second project→daemon kill + relaunch recovery→down.
- launchd smoke script (manual): install/kickstart/bootout, upgrade-in-place, shutdown intent honored by auto-bootstrap.
- UI: `make app`, launch, drive against the live daemon, click-to-open verified, screenshot review of dropdown + dashboard (design judged by render, not tests).
- Hook end-to-end: `devctl hook install` in a test project, fresh session + forced compaction, confirm injected context; confirm silence in an untrusted project and with the daemon stopped.
