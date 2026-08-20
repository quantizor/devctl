---
"devctl": patch
---

Antigravity sessions now rediscover running servers the way Claude Code and Cursor already do. `devctl hook install --harness antigravity` (also offered at first run and in Settings when `~/.gemini` is present) wires a PreInvocation hook so a new session sees live `devctl` status instead of spawning duplicates. `devctl hook uninstall --harness antigravity` removes it.
