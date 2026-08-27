---
"devctl": patch
---

Servers under a discarded checkout now stop on their own within about a minute of the checkout disappearing, instead of waiting for a reboot or a machine-wide `devctl status --all`. The daemon stats every registered project every 30 seconds and prunes a path only after it is missing on two consecutive sweeps, so one flaky stat (a network mount blip, a slow Finder move) never tears down a live project.
