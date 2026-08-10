---
"devctl": patch
---

A non-finite `--timeout` no longer crashes the command. Passing `--timeout inf` (or a value large enough to overflow) to `ensure`, `wait`, `restart`, `up`, or `switch` took the process down with a runtime error instead of running. Such a value now falls back to the normal response deadline, which matters most for the agents and scripts that drive devctl with computed timeouts.
