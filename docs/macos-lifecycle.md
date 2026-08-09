# macOS lifecycle notes

Hard-won platform behavior behind devctl's process teardown, launchd supervision, SMAppService registration, and the ad-hoc-signature rebind path. Verified 2026; re-verify before building on any of it, since these are Apple internals that move between OS releases.

## Process sessions

- swift-subprocess `createSession = true` gives the child a fresh session, so `pgid == pid`. Group-directed teardown relies on this.

## launchd

For the launchd phase:

- Jobs get a minimal PATH without Homebrew. The design captures the user's shell PATH at install time to work around this.
- `ThrottleInterval` defaults to 10s between respawns.
- `ExitTimeOut` (SIGTERM to SIGKILL) defaults to 20s per `launchd.plist(5)`. A sequential drain of many servers at 7s grace each can exceed it, so set it deliberately. 60 is the ceiling: launchd clamps anything larger and logs `ExitTimeOut is larger than the maximum allowed`.
- User agents live in domain `gui/<uid>`, never `system`. `launchctl list`/`print` answer differently depending on the calling context.

## SMAppService

- `SMAppService.Status` is `enabled = 1` and `requiresApproval = 2`, easy to misread from a raw value in a log.
- `enabled` means a registration exists, not that the job is loaded: after `launchctl bootout` or a replaced bundle the status still reads `enabled` while nothing runs, and `register()` on an already-registered service is a no-op, so the only way back is unregister + register.
- Expect launchd to log `Unknown key for plist importer (key: SHA256 type: data)` on every SMAppService submit. That key is Apple's, not ours.

## BTM launch constraint and the ad-hoc CDHash rebind saga

- The BTM (Background Task Management) launch constraint pins the Team ID when one is present, and a Team ID survives a rebuild, so a Developer ID signed upgrade spawns immediately. Ad-hoc has no Team ID, so the constraint pins the CDHash, which every rebuild changes: that is the whole reason the rebind path exists. `make app` and `make dmg` pick a Developer ID identity automatically, so this only bites a build made where the keychain has none.
- Replacing `Contents/Helpers/devctld` under an ad-hoc signature while the BTM item still exists binds the item to the old CDHash, and the next spawn dies with `SIGKILL (Code Signature Invalid)` / Launch Constraint Violation, recorded as a `devctld-*.ips` in `~/Library/Logs/DiagnosticReports`.
- Unregister does NOT clear this. `sfltool dumpbtm` (the store is `BackgroundItems-v16.btm` on macOS 26; `sfltool` needs neither sudo nor Full Disk Access) and the `registerLaunchItem: found existing item` log line both show the same item UUID across unregister+register, so re-registering only re-arms the same doomed constraint and burns another 10s `ThrottleInterval` per attempt.
- The constraint clears only when BTM invalidates the item, which xpcproxy triggers on the next spawn attempt rather than on a timed background sweep, and the item UUID changes when it does. Waiting longer for a spawn cannot help, because the job is killed on exec rather than running slowly.
- Diagnose an upgrade that comes up slowly by reading the BTM item UUID and the crash report, never by timing alone.
- DMG upgrades write `agent.rebind` and refuse to replace if the agent is still loaded. `AgentRebindPolicy` bounds how long the app waits before escalating; those waits only cover a job that is genuinely still spawning, not a constraint kill.

## DMG and /Applications share a bundle id

- DMG and `/Applications/devctl.app` share a bundle id: never register the SMAppService agent from the volume copy, and never treat `openApplication` of Applications as success unless a different pid is actually running from that path (`createsNewApplicationInstance` plus a peer wait).
- Deep links for daemon control use `open -a /Applications/devctl.app` so the volume copy cannot steal them.
