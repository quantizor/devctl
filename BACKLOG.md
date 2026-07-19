# devctl backlog

Open work only; entries are removed by the change that resolves them.

- Orphan re-adoption without the bounce: after a daemon crash, re-adopt live orphan servers (pid + start-time match, resume spool tailing) instead of group-kill + restart. Blocked on: exit codes are unknowable for non-children; needs a design for degraded forensics.
- Reverse proxy on :80/:443 routing by host signature, making ports disappear from `*.localhost` URLs (Valet/Herd territory).
- MenuBarExtraAccess (orchetect) if `.window` presentation quirks bite in practice.
- Developer ID signing + notarization + Homebrew tap for OSS release; SIGN_IDENTITY variable already exists in the bundle script.
- Verify the ProcessType=Interactive claim (App Nap/QoS throttling of own-session children) empirically during Phase 4.
- Field-level config editing in the dashboard to preserve devservers.json formatting instead of normalizing writes.
- Branch switching per project (Evan, 2026-07-18): switch a project's checkout to a named branch and run its declared lifecycle commands (install, prepare, serve) before bringing servers up; the usage patterns (which commands, what order) are configured by the agent, likely a `lifecycle` block in devservers.json plus a `devctl switch <branch>` verb. Needs design for dirty-tree safety and worktree interplay.
