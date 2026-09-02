---
"devctl": patch
---

`devctl uninstall` now also removes Start at Login and the leftover background item in System Settings, so the app cannot launch itself after you remove it. A DMG-installed app is moved to the Trash; Homebrew's copy is left for brew to remove. `--purge` also deletes preferences and caches.
