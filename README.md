# devctl

A macOS menu bar command center for local dev servers, built so coding agents never lose track of the servers they started.

A launchd-supervised daemon owns every server process. Sessions come and go, contexts compact, terminals close: the servers, their logs, and their crash forensics stay. A CLI designed for agents (stable `--json` everywhere) and a quiet menu bar app for you sit on top of the same unix socket.

## Why

Agents forget their dev servers. After a context compaction they spawn duplicates, tail dead logs, and fight over ports. devctl gives them one idempotent verb (`devctl ensure web`) that always lands in the same place, a session hook that re-teaches every new or compacted session what is running, and a `why` command that turns a broken server into a root-cause diagnosis.

## Quick start

```sh
make install          # binaries to ~/.local/bin, app to /Applications, daemon installed
cd your-project
devctl register --name web --cmd bun --cmd run --cmd dev --port 3000
devctl ensure web     # idempotent: healthy is a no-op
devctl why web        # root cause when something breaks
devctl hook install   # Claude Code sessions rediscover servers automatically
```

Or commit a `devservers.json` at the project root (multiple servers, dependencies, healthchecks, `*.localhost` host signatures, multi-headed proxies, lifecycle playbooks); `devctl up` brings the whole project up in dependency order. The full CLI contract lives in `docs/cli-contract.md`.

## The parts

- `devctld`: the daemon. Spool-file output capture (children survive daemon restarts without SIGPIPE), process-group plus descendant-sweep teardown, health-gated phases, crash forensics, structured logs with correlation marks, a unified event feed.
- `devctl`: the CLI. `ensure`, `wait`, `up`/`down`, `logs --since-mark`, `mark`, `events`, `why`, `open`, `switch`, `lock` (pause servers sharing a resource while a test harness runs), `doctor`, and launchd management. Agents are the first-class consumer.
- `devctl.app`: the menu bar. Presence dots with counts, per-project rows with click-to-open heads (pinnable), crash notifications, a dashboard with live logs, an event timeline, and a validating config editor. Every server and head is Spotlight-searchable.

## Building

`make build` and `make test`; `scripts/smoke.sh` is the end-to-end gate. No Xcode required, ever: the app bundle is assembled by a checked-in script. See `CLAUDE.md` for the codebase map and `CONTRIBUTING.md` for adding an agent-harness adapter.
