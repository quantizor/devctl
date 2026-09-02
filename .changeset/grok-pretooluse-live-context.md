---
"devctl": patch
---

Grok Build sessions receive a live server snapshot. `devctl hook install --harness grok` wires PreToolUse (the event Grok delivers into context, after the first tool of a turn) and UserPromptSubmit (the per-turn gate) alongside the existing home rule, and removes a leftover SessionStart or Stop registration of the same command. Re-run install to upgrade a SessionStart-only hook; `devctl doctor` reports the old install as missing.
