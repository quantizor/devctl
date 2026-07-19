# devctl backlog

Open work only; entries are removed by the change that resolves them.

- DMG distribution with one-click install (Evan, 2026-07-19): a simple dmg builder (scripts/make-dmg.sh from the existing bundle pipeline; hdiutil + a drag-to-Applications layout) where first launch of devctl.app completes setup itself: install the CLI/daemon binaries from the app bundle's Resources, run daemon install, and auto-detect installed agent harnesses (Claude Code via ~/.claude presence → offer/perform `hook install --harness claude`), with a small first-run panel reporting what was set up. Requires Developer ID signing + notarization (already backlogged) to be download-safe; sequence the two together.
- Orphan re-adoption without the bounce: after a daemon crash, re-adopt live orphan servers (pid + start-time match, resume spool tailing) instead of group-kill + restart. Blocked on: exit codes are unknowable for non-children; needs a design for degraded forensics.
- Reverse proxy on :80/:443 routing by host signature, making ports disappear from `*.localhost` URLs (Valet/Herd territory).
- MenuBarExtraAccess (orchetect) if `.window` presentation quirks bite in practice.
- Developer ID signing + notarization + Homebrew tap for OSS release; SIGN_IDENTITY variable already exists in the bundle script.
- Verify the ProcessType=Interactive claim (App Nap/QoS throttling of own-session children) empirically; unconfirmed since install.
- swift-subprocess 0.5 occasionally fatals in its kqueue AsyncIO cleanup at process exit ("Failed to close kqueue fds: Bad file descriptor"), seen once under parallel test load; harmless to the long-lived daemon but track against upstream releases (pinned revision in Package.swift).
- Field-level config editing in the dashboard to preserve devservers.json formatting instead of normalizing writes.
- `devctl hook install` (and possibly `register`) should offer the one-line CLAUDE.md/AGENTS.md discovery stanza for the project, per the design doc; candor's was written by hand. Until then a new project's agents learn about devctl only from the injected context.
- devctl.app accessibility pass: the popover's borderless footer buttons report no AX name to System Events (missing value); audit the app with the a11y toolchain and label every control.
- Spotlight thumbnails: verify the icon renders in the real Spotlight results UI (indexing reports ok and thumbnailData is set from the config icon; the visual result awaits a human Spotlight search).
