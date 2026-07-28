---
"devctl": minor
---

Two git worktrees of one repo can both run under supervision without editing `devservers.json`. When a sibling checkout already holds the committed port, `ensure` auto-rebinds to a free port, keeps the main origin on the declared host, and gives the worktree an ephemeral `worktree-*.<preferred>.localhost` URL; unrelated projects and unmanaged listeners still get a loud `port-held` naming the holder. Session context and ensure/status JSON warn about latent and rebound conflicts so agents use the live URL, and `lock --no-pause` lets a harness take the mutex without stopping the server it reuses. Discarding a worktree stops its servers and frees the ephemeral host without a manual doctor pass. Bad-state servers in the session-start block still lead with a `devctl why` recommendation and a stderr line count, never the server's own output.
