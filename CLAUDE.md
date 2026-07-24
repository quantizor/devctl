# devctl

macOS menu bar command center for local dev servers, built so coding agents never lose track of running servers across compaction and session boundaries. All Swift, no Xcode. Design spec and phase plan: docs/design.md (the map for everything not yet built). CLI JSON contract: docs/cli-contract.md. Open work: BACKLOG.md. Commit and changeset hygiene: CONTRIBUTING.md.

Identity and stack
- Swift 6.3 toolchain, swift-tools-version 6.2, Swift 6 language mode with strict concurrency. macOS 14+, single SPM package.
- Isolation is set per target in Package.swift: .defaultIsolation(nil) everywhere except DevCtlApp, which is .defaultIsolation(MainActor.self).
- Deps (exactly two): swift-argument-parser (CLI only) and swift-subprocess (daemon only; pre-1.0, revision-pinned, isolated behind the ProcessLauncher protocol so a posix_spawn fallback can swap in without touching callers). The revision pin is load-bearing; do not loosen it.
- Three products, one daemon: devctld owns all server processes; devctl (CLI) and devctl.app (SwiftUI MenuBarExtra) are thin clients over a unix socket (default ~/Library/Application Support/devctl/daemon.sock; DEVCTL_SOCKET overrides; /tmp fallback near the sun_path limit), NDJSON protocol. devctl daemon install/uninstall/start/stop/restart manage the LaunchAgent (dev.quantizor.devctl); tests and the smoke gate run devctld --foreground.

Codebase map
- Sources/DevCtlKit: shared core, the unit-test target of record. Models.swift (specs, phases, ServerStatus), Wire.swift (JSONCoding, typed request/response/event frames, NDJSON framing, stable error codes), Client/DaemonClient.swift (blocking-POSIX socket actor used unchanged by CLI and app), Paths/Paths.swift (path constants, canonical project path, atomic write + defensive load, portable SHA-256), DeepLink/ (parse/serialize + DeepLinkRunner + notification action map), Log/DevCtlLog.swift (OSLog facade with a recording backend for tests).
- Sources/DevCtlDaemonCore: daemon logic as a library. Supervisor/ (ServerSupervisor actor per server: spawn, spool capture, health-gated phase machine, ensure/wait, group + descendant teardown; the ProcessLauncher seam; ProcessTree sysctl sweep), Health/ (EffectiveHealthcheck resolution, the HealthProber seam with the real network prober, PortGuard lsof diagnostics), Registry/ (owner of registry.json and state.json), Control/ (Router method dispatch + port pre-check + resource-lock registry with dead-holder auto-release + NWListener ControlServer).
- Sources/devctld: thin main; identical behavior under launchd and --foreground (tests and the smoke gate use foreground).
- Sources/devctl: CLI (swift-argument-parser); LaunchdAdmin (launchd lifecycle; install drains via daemon.shutdown before bootout), HookSupport (AgentContext + HarnessAdapter registry; adding a harness: CONTRIBUTING.md), Switch (branch switching + lifecycle playbooks), Lock (run-under-resource-lock), Link / x-url (deep links).
- Sources/DevCtlApp: menu bar app (DaemonModel 2s-polling model + crash notifications with Open/Why actions; PresenceLabel is AppKit-drawn colored tally dots only with renderingMode(.original); popover autogrows to a cap; nested head rows with UserDefaults-persisted pins; DashboardView logs/timeline/config tabs; SpotlightIndexer best-effort Core Spotlight; AppDeepLink handles `devctl://` and notification actions). Pure DaemonClient consumer.
- Sources/fixture-server: test double dev server (heartbeat printer; TCP-listen, timed-exit, grandchild, ignore-sigterm, binary, flood modes; see its header comment).

Commands
- make build: swift build -c release (all products)
- make test: swift test; budget under 30s, the run prints the live timing
- scripts/smoke.sh: the end-to-end gate. Debug-builds, boots a real devctld on a temp socket, then asserts register/start/status, spool capture, health/ensure/wait, port conflicts, marks/events/why, resource locks (pause + refused ensure + resume), whole-group death on stop, child survival across a daemon kill, `link`/`x-url` deep-link dispatch, and that the assembled app declares `CFBundleURLSchemes=devctl`. Run it after touching the supervisor, wire protocol, CLI, or deep links.
- scripts/smoke-deeplink.sh: Launch Services E2E for `devctl://` (warm + cold `open`). Requires a GUI session; run before merging URL-scheme work. OSLog scrape is strict on a tty (`DEVCTL_OSLOG_STRICT=1` forces it).
- scripts/smoke-launchd.sh: the REAL LaunchAgent lifecycle (install, restart bounce + re-ensure, install-upgrade bounce + re-ensure, deliberate-stop intent, auto-bootstrap resurrection, uninstall). Mutates the user launchd domain; refuses to run if a devctl agent is already installed; leaves nothing behind.
- make app: assembles devctl.app via scripts/make-app-bundle.sh (no Xcode; ad-hoc signed; SIGN_IDENTITY upgrades; declares the `devctl://` URL scheme). make install: binaries to ~/.local/bin, app to /Applications, daemon install.
- Unified logging: subsystem `dev.quantizor.devctl` (categories daemon, supervisor, health, app, deeplink). Stream with `log stream --predicate 'subsystem == "dev.quantizor.devctl"' --level debug`. Child stdout/stderr stay in spool files; OSLog is for devctl's own behavior.
- Deep links: `devctl://open|ensure|stop|why/<project-slug>/<server>[/<head>]` (query form also accepted). `devctl link` prints; the app handles via Launch Services; `devctl x-url` runs the same runner for smoke.

Hard rules
- Output capture is spool-file fds, never pipes: children must survive daemon death without SIGPIPE. Do not introduce pipe-based capture anywhere.
- Teardown signals the process group AND every live descendant found by a sysctl sweep, snapshotted before the first signal (children that setpgid/setsid escape the group; orphans reparent to launchd and fall out of the parent-pid chain). Escalation unions the snapshot with a fresh sweep. Keep both halves when touching stop().
- All JSON goes through JSONCoding: sorted keys, ISO-8601 UTC with milliseconds, no interior newlines. Never construct a raw JSONEncoder or JSONDecoder; the golden tests and NDJSON line framing depend on this determinism.
- Wire methods are typed end to end: the daemon sniffs the {id, method} head, then re-decodes the full typed frame. A new method extends WireMethod plus Codable params/result types in Wire.swift; no untyped dictionaries on the wire.
- Every CLI command supports --json with a stable schema generated from the shared Codable types; failures emit {ok:false, error:{code,message,hint}} on stdout, hint being the literal remediation command. Error codes grow append-only. Golden tests in Tests/DevCtlKitTests assert exact schema strings; a changed field is an API change: update docs/cli-contract.md in the same commit, then the golden.
- Structured log files keep per-file monotonic timestamps (clamp on append); the since-query binary search depends on it.
- The daemon never acts on a project's committed config before trust is recorded; the SessionStart hook never emits raw log lines or command strings into agent context (child output is attacker-influenceable).
- State files load defensively: parse failure quarantines to .corrupt-<timestamp> and continues; never fatal (a startup parse crash under launchd KeepAlive loops forever). Corollary: new fields on persisted types (registry, state) stay optional so existing files keep parsing.
- Registry/state writes are temp + fsync + rename.
- Binary upgrades stage and rename(2); never overwrite a running signed Mach-O.

Engineering rules
- Types are law: no unsafe casts or force-unwraps in product code to silence the checker (tests prefer #require); strict concurrency stays on. If a type will not express, restructure the code.
- Backward compatibility binds only the public surfaces: the CLI JSON contract and the wire protocol (append-only error codes; proto bump on a breaking change). All internal code is freely rewritable.
- Fix at the cause, never the symptom: no sleeps over races, no timeouts raised or goldens updated to green without explaining the diff, no swallowed errors. try? is a suppression unless loss is genuinely acceptable at that site. When the cause is out of reach, name the suppression as a suppression and add it to BACKLOG.md; nothing is deferred silently.
- Tests ship with every feature and cover logic and headlessly-verifiable behavior, never visuals (how the app looks is judged by rendering and viewing). Branch coverage stays above 80% on DevCtlKit and DevCtlDaemonCore (swift test --enable-code-coverage prints the live figure). Prefer exact full-output assertions; validate a new test red then green; treat golden drift as a suspected regression before updating the golden.
- Tests use Swift Testing (@Test, #expect, #require), not XCTest. Suites run in parallel by default; anything sharing a daemon, socket, or port uses @Suite(.serialized).
- Comments are block comments (/** ... */) so they surface as hover docs; they explain the current code's non-obvious decisions and never narrate edits or history.
- Fields in type declarations, initializers, and literals are alphabetized; keep a non-alphabetical order only where the sequence is load-bearing and say why in a comment. Persisted names (JSON keys, file names) are plain English a non-engineer would read.
- Error messages assume the reader knows nothing of internals: what happened, where, and the exact fix; wire errors carry a stable code and a hint that is the literal command to run.
- Prose (docs, commits, PRs): American English, no em-dashes (use a colon, comma, or period), plain language over jargon, no attribution footers anywhere. PR and changeset descriptions lead with user-facing impact, not mechanism.
- Git: never git stash; use temp commits. A dependency change updates Package.resolved in the same commit and is verified by a build. Commit messages, Changesets (when to write one), and release tagging live in CONTRIBUTING.md; agents never bump versions or publish.
- Docs carry no measured drift-prone numbers (timings, counts, coverage); state the budget and the command that prints the live figure. Docs track current state, never completions or history. BACKLOG.md is the only backlog, holds open work only, and the change that resolves an entry removes it.
- Performance: hot paths (spool tailer, log query) get temporary microbenchmarks before an approach is chosen; a governor (throttle, cap) is never the fix for a cost problem, make the work itself cheaper.
- No database, no migrations; on-disk compatibility is the defensive-load rule above.
- Before calling work done: hunt the input that breaks it, run make test and scripts/smoke.sh, and separate what you observed (file:line, command output) from what you inferred.

Stack notes (verified 2026; re-verify before building on them)
- swift-subprocess createSession = true gives the child a fresh session, so pgid == pid, which group-directed teardown relies on.
- launchd, for the launchd phase: jobs get a minimal PATH without Homebrew (the design captures the user's shell PATH at install). ThrottleInterval defaults to 10s between respawns. ExitTimeOut (SIGTERM to SIGKILL) defaults to 20s per launchd.plist(5); a sequential drain of many servers at 7s grace each can exceed it, so set it deliberately. User agents live in domain gui/<uid>, never system, and launchctl list/print answer differently depending on the calling context.

Aesthetic
Quiet instrument panel: monochrome SF Symbols glyph, tally-light status dots (subtle breathing animation on starting), dense but calm typography, no chrome. State changes register visibly but never shout. Visual changes are judged by rendering and viewing, never asserted in unit tests.
