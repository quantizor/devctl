# devctl

macOS menu bar command center for local dev servers, built so coding agents never lose track of running servers across compaction and session boundaries. All Swift, no Xcode. Design spec and rationale: docs/design.md. CLI JSON contract: docs/cli-contract.md. Open work: BACKLOG.md.

Identity and stack
- Swift 6.3, Swift 6 language mode, strict concurrency. macOS 14+ (app), single SPM package.
- Deps (exactly two): swift-argument-parser (CLI), swift-subprocess pinned exact (daemon; pre-1.0, isolated behind ProcessLauncher protocol).
- Three products, one daemon: devctld (launchd LaunchAgent) owns all server processes; devctl (CLI) and devctl.app (SwiftUI MenuBarExtra) are thin clients over a unix socket at ~/Library/Application Support/devctl/daemon.sock, NDJSON protocol.

Codebase map
- Sources/DevCtlKit: shared core, the unit-test target of record. Models, devservers.json codec + validation + topo sort, wire protocol + NDJSON codec, DaemonClient (POSIX socket actor), log line format + query engine, path constants + atomic writes.
- Sources/DevCtlDaemonCore: daemon logic as a library. ServerSupervisor (spawn/teardown/spool tailer), health probes, registry + state store, LogStore, ControlServer (NWListener + router).
- Sources/devctld: thin main; identical behavior under launchd and --foreground (tests use foreground).
- Sources/devctl: CLI (swift-argument-parser).
- Sources/DevCtlApp: menu bar app, pure DaemonClient consumer, default-MainActor isolation.
- Sources/fixture-server: test helper (TCP/HTTP responder; crash/grandchild/ignore-sigterm/binary/flood modes).
- docs/design.md: ratified architecture (lifecycle semantics, spool capture, trust model, host signatures).
- docs/cli-contract.md: every command's JSON schema and per-phase behavior; golden tests enforce it; schema changes are API changes and update this file first.

Commands
- make build: swift build -c release (all products)
- make test: swift test (must stay under 30s)
- make app: assemble devctl.app without Xcode (scripts/make-app-bundle.sh, ad-hoc signed)
- make install: binaries to ~/.local/bin, app to /Applications, devctl daemon install

Hard rules
- Output capture is spool-file fds, never pipes: children must survive daemon death without SIGPIPE. Do not introduce pipe-based capture anywhere.
- Structured log files keep per-file monotonic timestamps (clamp on append); the since-query binary search depends on it.
- Every CLI command supports --json with a stable schema generated from the shared Codable types; failures emit {ok:false, error:{code,message,hint}} on stdout. Golden tests in Tests/DevCtlKitTests lock these.
- The daemon never acts on a project's committed config before trust is recorded; the SessionStart hook never emits raw log lines or command strings into agent context.
- State files load defensively: parse failure quarantines to .corrupt-<timestamp> and continues; never fatal.
- Binary upgrades stage and rename(2); never overwrite a running signed Mach-O.
- Registry/state writes are temp + fsync + rename.

Aesthetic
Quiet instrument panel: monochrome SF Symbols glyph, tally-light status dots (subtle breathing animation on starting), dense but calm typography, no chrome. State changes register visibly but never shout. Visual changes are judged by rendering and viewing, never asserted in unit tests.
