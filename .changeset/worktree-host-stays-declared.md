---
"devctl": minor
---

Servers in a linked git worktree keep the project's declared host instead of getting an ephemeral `worktree-<label>.<preferred>.localhost` origin. Every `*.localhost` name resolves to loopback, so the label never disambiguated a bind, while the third-level subdomain broke any auth config an app pins to one origin (an OAuth callback, a cookie domain, a CORS allow list, a trusted-origins check). Sibling worktrees of one repo are still told apart: the shared committed port auto-rebinds as before, and the worktree name surfaces as a display value (`worktree` and `mainProject` on status JSON, a `worktree: <label>` line in `devctl status` human output and in `config check`, and a banner line in session context). The menu bar app and Spotlight show a worktree server under its project family (`myproj · review`), so searching for the project name still finds it.
