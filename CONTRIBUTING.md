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

The release DMG build runs with `DEVCTL_REQUIRE_SIGNING=1`, so a runner missing the certificate fails the build rather than shipping an ad-hoc image Gatekeeper would disable.

Local path: `make release-dmg` (Developer ID signed, notarized, and stapled; fails loudly if signing or notary credentials are missing), then `gh release upload vX.Y.Z dist/devctl-X.Y.Z.dmg`.

## Homebrew tap

devctl is distributed as a cask through the self-owned tap `quantizor/homebrew-tap` (installed as `brew install --cask quantizor/tap/devctl`). A tap is required rather than optional: the official `homebrew/cask` needs 225 stars and a 30-day-old repo, and a tapless cask can never be upgraded (brew re-reads the definition saved at install time, so the version always compares equal).

The release workflow bumps the tap automatically on publish. The cask's structure (`packaging/homebrew/devctl.rb`), the `bump-homebrew-cask` workflow that injects each release's `version` and `sha256`, and the `scripts/smoke-cask.sh` gate are all documented in docs/releasing.md. One additional repository secret drives the bump:

- `HOMEBREW_TAP_TOKEN`: a fine-grained PAT with `contents: write` on `quantizor/homebrew-tap` (the default `GITHUB_TOKEN` cannot push across repos). A GitHub App token via `actions/create-github-app-token` is the equivalent alternative.

Anything in the cask's `uninstall` runs on every `brew upgrade`, not only on uninstall, so it is limited to unregistering the background agent (the app re-registers it when brew relaunches). It must never remove hooks or data: nothing restores those automatically. Full removal is `devctl uninstall`.

## Adding an agent-harness adapter

The session-context payload is harness-agnostic: `devctl context` prints a fenced plain-text block describing the current project's servers, and `devctl statusline` prints a one-line presence summary from statusline stdin JSON. Wiring those into a harness is the only per-harness work.

1. Conform to `HarnessAdapter` in `Sources/devctl/HookSupport.swift`: a `name` (the `--harness` value), the `settingsURL` of the file the harness reads, and an idempotent `install(devctlPath:)` that merges a session-start hook into that file without clobbering what is already there. Read and write it with the protocol's own `loadSettings()` and `writeSettings(_:)` rather than reaching for `Data(contentsOf:)`: `install` writes back everything it reads, so a read that answers "empty" for a file that exists turns the merge into a replacement of settings devctl does not own. `loadSettings` refuses a file it cannot parse for that reason, and returns an empty dictionary only when there is genuinely nothing there to lose.
2. If the harness wants a structured payload (as Claude Code does with `hookSpecificOutput.additionalContext`, or Cursor with `{additional_context}`), add a hidden subcommand like `HookClaudeSessionStart` / `HookCursorSessionStart` that adapts the `HookContext.render` output (a thin socket fetch over the pure `AgentContext.render` renderer in DevCtlKit) to that shape. Keep the guarantees: exit 0 always, fast, silent when there is nothing to say, never auto-starting the daemon, and never emitting raw log lines or command strings (child output and committed configs are attacker-influenceable). Resolve the session directory via `HookSessionCwd` (Cursor: `workspace_roots` / `CURSOR_PROJECT_DIR`; Claude: `cwd`).
3. Register the adapter in `harnessAdapters` and document the harness in `docs/cli-contract.md` under `devctl hook install`.

A harness that only supports plain-text injection needs no adapter code at all: point its hook at `devctl context`. Shipped adapters today: `claude`, `cursor`.
