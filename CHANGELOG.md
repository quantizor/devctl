# Changelog

All notable changes to this project are documented here. Releases are tagged
`vX.Y.Z` on GitHub (same scheme Changesets uses for this root package).

## 1.2.0

### Minor Changes

- [#4](https://github.com/quantizor/devctl/pull/4) [`40d3e97`](https://github.com/quantizor/devctl/commit/40d3e9741f79b110e08d1ede6515c1ec4636e3c9) - Add Cursor sessionStart harness (`devctl hook install --harness cursor`) so Agent sessions get live `<devctl-servers>` context.
- [#6](https://github.com/quantizor/devctl/pull/6) [`d5ebe80`](https://github.com/quantizor/devctl/commit/d5ebe80704003103c90a8693a53ea5ae044ca840) - Open servers and run lifecycle verbs via `devctl://` URLs (menu bar app + `devctl link` / `devctl x-url`), with unified logging under subsystem `dev.quantizor.devctl`.

### Patch Changes

- [#6](https://github.com/quantizor/devctl/pull/6) [`46ab7b1`](https://github.com/quantizor/devctl/commit/46ab7b17bcf30cbbd336b7e3d7257b0b76586779) - Warn in `config check` when a host or url uses bare `localhost` / `127.0.0.1` instead of a `<slug>.localhost` origin.
- [#6](https://github.com/quantizor/devctl/pull/6) [`4695414`](https://github.com/quantizor/devctl/commit/4695414a2995b0d6f0d3413a1c09c8ecd4e24903) - After `hook install`, print a one-bullet CLAUDE.md / AGENTS.md discovery tip for the project (paste-only; never auto-edits those files).
- [#6](https://github.com/quantizor/devctl/pull/6) [`67d83e7`](https://github.com/quantizor/devctl/commit/67d83e7a569a55735f040ec20b2cf6cc5e3ad4c2) - Restore config-defined servers after reboot and `daemon install` upgrades (merged config+registry recover; install re-ensures like restart).
- [#6](https://github.com/quantizor/devctl/pull/6) [`631a50f`](https://github.com/quantizor/devctl/commit/631a50fe59a6b620eb31d084a6357026e7353354) - Spotlight entries use `<project> · <head>` titles with a `devctl · <url>` subtitle for clearer discovery.

## 1.1.0

### Patch Changes

- Fixed a health check issue with some dev servers that primarily communicate over IPv6.
- Many design improvements.
- Keyboard navigation.
- Sorting & Filtering.

## 1.0.0

Initial public release.
