---
"devctl": patch
---

Installing or restarting the daemon no longer floods the menu bar with false "server crashed" alerts for the expected bounce, and boot restore finishes before clients connect so upgrade re-ensure does not race and leave servers on a bad port. `devctl why` also diagnoses file-backed projects correctly, and an unexpected server exit tears down leftover child processes so the next ensure is not blocked by stale locks.
