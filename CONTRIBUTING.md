# Contributing to devctl

devctl is a personal tool first; issues and patches are welcome all the same. Read `CLAUDE.md` (or its `AGENTS.md` symlink) for the codebase map, invariants, and commands, and `docs/cli-contract.md` for the JSON surface. `make test` and `scripts/smoke.sh` must pass; `scripts/smoke-launchd.sh` exercises the real launchd lifecycle if your change touches daemon management.

## Adding an agent-harness adapter

The session-context payload is harness-agnostic: `devctl context` prints a fenced plain-text block describing the current project's servers, and `devctl statusline` prints a one-line presence summary from statusline stdin JSON. Wiring those into a harness is the only per-harness work.

1. Conform to `HarnessAdapter` in `Sources/devctl/HookSupport.swift`: a `name` (the `--harness` value) and an idempotent `install(devctlPath:)` that merges a session-start hook into the harness's settings without clobbering what is already there.
2. If the harness wants a structured payload (as Claude Code does with `hookSpecificOutput.additionalContext`), add a hidden subcommand like `HookClaudeSessionStart` that adapts `AgentContext.render` output to that shape. Keep the guarantees: exit 0 always, fast, silent when there is nothing to say, never auto-starting the daemon, and never emitting raw log lines or command strings (child output and committed configs are attacker-influenceable).
3. Register the adapter in `harnessAdapters` and document the harness in `docs/cli-contract.md` under `devctl hook install`.

A harness that only supports plain-text injection needs no adapter code at all: point its hook at `devctl context`.
