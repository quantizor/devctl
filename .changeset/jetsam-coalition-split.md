---
"devctl": patch
---

A memory-hungry dev server no longer takes the background daemon down with it. Under the menu bar agent, each server now runs as its own launchd job, so macOS can reclaim that server's memory without killing every other server the daemon is supervising.
