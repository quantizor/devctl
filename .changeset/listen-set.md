---
"devctl": patch
---

A supervised server that also binds an extra port (Node's inspector) or hops off its claimed port after it is healthy is named as the holder of that port. `devctl doctor` reports it, lock resume waits for it to drop, and a sibling checkout will not steal it.
