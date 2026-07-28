---
"minor"
---

Lock resume waits until claimed ports are free before re-ensuring, so a pause no longer races a dirty bind. Composite servers declare a port span or named subports so sibling worktrees rebind a whole claim block (relative offsets move, absolute ports stay singleton), and `devctl why` keeps the refusal lines from the last run across ensure retries instead of going blank on exit 0.
