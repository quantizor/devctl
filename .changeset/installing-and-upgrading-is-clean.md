---
"devctl": patch
---

Installing and upgrading devctl from the DMG is clean, with none of the glitches that used to appear around the handoff to Applications.

Installing no longer leaves two menu bar apps running. A second copy of the same app doubles everything you see: two icons, two pollers, and two notifications for one crash. Nothing prevented it, and the install hands off by asking macOS for a new instance by name, so any second trigger produced one, whether that was the relaunch button racing the automatic handoff, a squatting copy that would not quit, or opening the app in Finder while it was already running. A copy that finds the same app already running now steps aside on its own, whichever way it was launched.

Upgrading no longer flashes two menu bar icons. Double-clicking the app in the disk image used to briefly show its icon next to the one for the copy already installed, before the handoff finished. The copy on the disk image now runs purely as an installer: it shows only its setup window and never adds a menu bar icon, so the single icon you see stays the installed one throughout. The disk image copy and the Applications copy still run side by side for the moment the handoff needs, since that pair is the one case where two is correct.

The disk image ejects right after you install. The daemon could end up running its program straight from the mounted image instead of the copy in Applications, because the image and the installed app share an identity and macOS sometimes preferred the mounted one; while that lasted the disk reported itself in use and refused to eject until the daemon happened to restart. The daemon now notices at startup when it is running from a mounted volume and relaunches itself from the installed copy first, so the image is free to eject as soon as you have dragged the app to Applications.

Confirming an upgrade now stops rather than replacing the app in Applications while an old copy is still running it, and says which app to quit. It used to try for a few seconds, give up quietly, and replace the bundle anyway, leaving that copy running code no longer on disk.
