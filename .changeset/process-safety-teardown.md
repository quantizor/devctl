---
"devctl": patch
---

Server teardown is now safe against pid reuse. Every signal devctl sends while stopping or cleaning up after a server is checked against the identity it recorded for that process while it was alive, so a pid the kernel has since handed to an unrelated process is never signaled. The deliberate-stop path and the crash-cleanup path now share one revalidated sweep, and the crash path, whose process is already gone, no longer directs a signal at its former process group at all.

`devctl stop` now also cleans up a descendant that escaped into the background. A server that spawns a helper which itself exits, leaving a grandchild reparented away, used to leave that grandchild running after a stop; the stop now sweeps the server's whole session, not only the processes still directly parented to it.

The daemon refuses to start rather than erase its own records. If a saved store (the registry, run state, or resource locks) exists but cannot be read, from an I/O error or too many open file descriptors, devctld now exits and lets launchd retry instead of treating the data as absent and overwriting it on the next write. A missing file still starts clean, and an unparseable one is still quarantined and rebuilt.
