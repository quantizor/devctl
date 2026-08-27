---
"devctl": patch
---

OpenCode is a supported agent harness. `devctl hook install --harness opencode` (also offered at first run and in Settings when `~/.config/opencode` is present) writes a managed `~/.config/opencode/devctl.md` that tells OpenCode to run `devctl context` before touching a server, wired through the `instructions` array of the winning global config file, so a new session discovers the servers without spawning duplicates. OpenCode has no session-start hook to inject live context into, so the standing instruction is the integration; instruction files already referenced by a losing `opencode.json` stay active after the entry lands in `opencode.jsonc`. `devctl hook uninstall --harness opencode` removes both halves.
