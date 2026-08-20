---
"devctl": patch
---

Grok Build is a supported agent harness. `devctl hook install --harness grok` (also offered at first run and in Settings when `~/.grok` is present) wires a session hook and a short home rule that tells Grok to run `devctl context` before touching a server, so a new session does not spawn duplicates. `devctl hook uninstall --harness grok` removes both.
