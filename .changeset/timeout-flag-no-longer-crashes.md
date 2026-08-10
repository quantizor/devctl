---
"devctl": patch
---

A non-finite `--timeout` no longer crashes the command or the daemon. Passing `--timeout inf` (or a value large enough to overflow) to `ensure`, `wait`, `restart`, `up`, `switch`, or `lock` took the command down with a runtime error, and the same value sent on to the daemon crashed the daemon itself, which then respawned under launchd. The command now falls back to its normal response deadline, and the daemon clamps any timeout it receives over its socket to a safe bound before use, so a crafted request cannot bring it down either. This matters most for the agents and scripts that drive devctl with computed timeouts.
