# devctl backlog

Open work only; entries are removed by the change that resolves them.

- Orphan re-adoption without the bounce: after a daemon crash, re-adopt live orphan servers (pid + start-time match, resume spool tailing) instead of group-kill + restart. Blocked on: exit codes are unknowable for non-children; needs a design for degraded forensics.
- Reverse proxy on :80/:443 routing by host signature, making ports disappear from `*.localhost` URLs (Valet/Herd territory).
- MenuBarExtraAccess (orchetect) if `.window` presentation quirks bite in practice.
- Populate Apple Developer ID + App Store Connect API secrets for `.github/workflows/release-dmg.yml` (and a Homebrew tap) so the Release→DMG dispatch can notarize on Actions; until then, mint locally (`SIGN_IDENTITY=… make dmg` + `scripts/notarize.sh` + `gh release upload`). `v1.3.0` already has a stapled DMG from the local path.
- App Intents / Shortcuts wrappers over the existing `DeepLink` verbs (`open`, `ensure`, `stop`, `why`) for Siri / Gemini-Siri and Control Center. The `devctl://` URL table and `DeepLinkRunner` are the shared surface; intents should call the runner, not reimplement dispatch. Also the next plausible path for Spotlight ranking (IndexedEntity) once Core Spotlight levers are exhausted.
- swift-subprocess 0.5 occasionally fatals in its kqueue AsyncIO cleanup at process exit ("Failed to close kqueue fds: Bad file descriptor"), seen once under parallel test load; harmless to the long-lived daemon but track against upstream releases (pinned revision in Package.swift).
- Field-level config editing in the dashboard to preserve `devservers.json` formatting instead of normalizing writes.
- Spotlight thumbnails: confirm config icons render in the real Spotlight UI. Within-app ranking levers are maxed (lastUsed preserved across sync, incremental index updates, live/pinned rankingHint, alternateNames). Outranking filesystem / Cursor Top Hits remains an Apple ceiling; do not chase without a new system API.
- Automatic port deconflicting / pre-spawn allocation: today is refuse (`port-held`) + observe framework bumps (`observedPort`). True auto-pick needs env injection, URL/head rewrite, and ephemeral-vs-committed policy.
