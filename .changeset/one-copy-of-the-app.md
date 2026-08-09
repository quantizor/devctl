---
"devctl": patch
---

Installing no longer leaves two menu bar apps running. A second copy of the same app doubles everything you see: two icons, two pollers, and two notifications for one crash. Nothing prevented it, and the install hands off by asking macOS for a new instance by name, so any second trigger produced one, whether that was the relaunch button racing the automatic handoff, a squatting copy that would not quit, or opening the app in Finder while it was already running. A copy that finds the same app already running now steps aside on its own, whichever way it was launched.

The copy on the disk image and the copy in Applications still run side by side for the moment the handoff needs, since that pair is the one case where two is correct.

Confirming an upgrade now stops rather than replacing the app in Applications while an old copy is still running it, and says which app to quit. It used to try for a few seconds, give up quietly, and replace the bundle anyway, leaving that copy running code no longer on disk.
