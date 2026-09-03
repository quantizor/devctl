---
"devctl": patch
---

The menu bar icon no longer quits itself as idle after macOS reclaims memory. The extra has no windows AppKit counts as "in use", so a memory-pressure pass was allowed to terminate it, and Start at Login only brings it back at the next login.
