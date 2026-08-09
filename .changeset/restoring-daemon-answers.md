---
"devctl": minor
---

A daemon that is coming back up no longer looks like one that is gone. While devctld restores supervised servers at boot it kept its socket closed, so every client got `daemon-unreachable`, which is the same answer a daemon that was never started gives. An agent polling across a `daemon install` or `daemon restart` read a busy daemon as a dead one and tried to start another.

The daemon now accepts as soon as its listener is up and says which state it is in. `devctl daemon status` reports `restoring` while it works, and any other command waits the window out instead of failing, saying on stderr what it is waiting for. Commands that reach the daemon mid-restore are refused with `daemon-starting` rather than served against half-restored state, so the ordering guarantee that made the socket closed in the first place is unchanged.
