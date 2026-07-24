# devctl backlog

Open work only; entries are removed by the change that resolves them.

- DMG distribution with one-click install (Evan, 2026-07-19): a simple dmg builder (scripts/make-dmg.sh from the existing bundle pipeline; hdiutil + a drag-to-Applications layout) where first launch of devctl.app completes setup itself: install the CLI/daemon binaries from the app bundle's Resources, run daemon install, and auto-detect installed agent harnesses (Claude Code via ~/.claude presence → offer/perform `hook install --harness claude`; Cursor via ~/.cursor presence → `hook install --harness cursor`), with a small first-run panel reporting what was set up. Requires Developer ID signing + notarization (already backlogged) to be download-safe; sequence the two together.
- Orphan re-adoption without the bounce: after a daemon crash, re-adopt live orphan servers (pid + start-time match, resume spool tailing) instead of group-kill + restart. Blocked on: exit codes are unknowable for non-children; needs a design for degraded forensics.
- Reverse proxy on :80/:443 routing by host signature, making ports disappear from `*.localhost` URLs (Valet/Herd territory).
- MenuBarExtraAccess (orchetect) if `.window` presentation quirks bite in practice.
- Developer ID signing + notarization + Homebrew tap for OSS release; SIGN_IDENTITY variable already exists in the bundle script.
- App Intents / Shortcuts wrappers over the existing `DeepLink` verbs (`open`, `ensure`, `stop`, `why`) for Siri / Gemini-Siri and Control Center. The `devctl://` URL table and `DeepLinkRunner` are the shared surface; intents should call the runner, not reimplement dispatch.
- swift-subprocess 0.5 occasionally fatals in its kqueue AsyncIO cleanup at process exit ("Failed to close kqueue fds: Bad file descriptor"), seen once under parallel test load; harmless to the long-lived daemon but track against upstream releases (pinned revision in Package.swift).
- Field-level config editing in the dashboard to preserve devservers.json formatting instead of normalizing writes.
- Spotlight thumbnails: confirm config icons render in the real Spotlight UI. Ranking above filesystem / Cursor Top Hits is a hard Apple ceiling (tried; stripped Recent Documents / jump-file chase 2026-07-24); do not reopen without a new system API.
- Automatic port deconflicting / pre-spawn allocation: today is refuse (`port-held`) + observe framework bumps (`observedPort`). True auto-pick needs env injection, URL/head rewrite, and ephemeral-vs-committed policy.
