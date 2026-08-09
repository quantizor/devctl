---
"devctl": patch
---

`devctl lock` now catches a change to a large database file that it used to miss. A lock resource above 8 MiB was fingerprinted by its head, its tail, its size, and its mtime, so a command that rewrote the middle while preserving all four was reported as no change at all. A local sqlite database is exactly the shape that happens to, and not noticing is the worst answer a check that exists to notice can give.

A file is now hashed whole at any size, read in chunks so the cost is memory-flat, and the identity no longer claims to be exact when it is not. A directory keeps a byte budget, since its cost is the sum over the whole tree and the fingerprint is taken twice per guarded command.
