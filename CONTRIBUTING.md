# Contributing to devctl

devctl is a personal tool first; issues and patches are welcome all the same. Read `CLAUDE.md` (or its `AGENTS.md` symlink) for the codebase map, invariants, and commands, and `docs/cli-contract.md` for the JSON surface. `make test` and `scripts/smoke.sh` must pass locally; `scripts/smoke-launchd.sh` exercises the real launchd lifecycle if your change touches daemon management. GitHub Actions (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on `macos-26` only: no smoke, no large runners.

## Commit and changeset hygiene

- Commits focus on why, not a file list; American English; no em-dashes; no attribution footers.
- Never `git stash` (use temp commits). Agents never bump versions or publish.
- User-facing changes get a Changeset (`npm run changeset`); see `.changeset/README.md`. Internal-only work (CI, agent docs, no-behavior refactors) never gets a changeset.
- Product version lives in `package.json`. `npm run version` (used by the Release workflow) syncs `DevCtlVersion.version` in `Sources/DevCtlKit/Model/Models.swift`.

## Releases

GitHub releases are driven by [Changesets](https://github.com/changesets/changesets). After changesets land on `main`, a Version Packages PR appears; merging it tags `vX.Y.Z` and opens the GitHub release. Nothing is published to npm: the root `package.json` is private and only tracks the product version.

A separate macOS workflow (`.github/workflows/release-dmg.yml`) builds a Developer ID-signed, notarized DMG and attaches it to that release. The Release job dispatches it after a successful publish (`workflow_dispatch`): a release created with `GITHUB_TOKEN` does not fire `release:published` on other workflows. Required repository secrets:

- `APPLE_DEVELOPER_ID_P12_BASE64` / `APPLE_DEVELOPER_ID_P12_PASSWORD`: exported Developer ID Application certificate
- `APPLE_SIGN_IDENTITY`: exact codesign identity string (for example `Developer ID Application: Name (TEAMID)`)
- `APPLE_API_KEY_BASE64` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER`: App Store Connect API key for `notarytool`

Local path: `SIGN_IDENTITY="Developer ID Application: …" make dmg` then `scripts/notarize.sh`, then `gh release upload vX.Y.Z dist/devctl-X.Y.Z.dmg`.

## Adding an agent-harness adapter

The session-context payload is harness-agnostic: `devctl context` prints a fenced plain-text block describing the current project's servers, and `devctl statusline` prints a one-line presence summary from statusline stdin JSON. Wiring those into a harness is the only per-harness work.

1. Conform to `HarnessAdapter` in `Sources/devctl/HookSupport.swift`: a `name` (the `--harness` value) and an idempotent `install(devctlPath:)` that merges a session-start hook into the harness's settings without clobbering what is already there.
2. If the harness wants a structured payload (as Claude Code does with `hookSpecificOutput.additionalContext`, or Cursor with `{additional_context}`), add a hidden subcommand like `HookClaudeSessionStart` / `HookCursorSessionStart` that adapts `AgentContext.render` output to that shape. Keep the guarantees: exit 0 always, fast, silent when there is nothing to say, never auto-starting the daemon, and never emitting raw log lines or command strings (child output and committed configs are attacker-influenceable). Resolve the session directory via `HookSessionCwd` (Cursor: `workspace_roots` / `CURSOR_PROJECT_DIR`; Claude: `cwd`).
3. Register the adapter in `harnessAdapters` and document the harness in `docs/cli-contract.md` under `devctl hook install`.

A harness that only supports plain-text injection needs no adapter code at all: point its hook at `devctl context`. Shipped adapters today: `claude`, `cursor`.
