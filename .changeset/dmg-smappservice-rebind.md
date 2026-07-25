---
"devctl": minor
---

Ship a DMG installer that places the app in Applications and registers the Login Items agent, keep resource locks across a daemon crash so paused servers resume, and rebind the helper after ad-hoc upgrades so the daemon returns in seconds instead of stalling on a codesign throttle.
