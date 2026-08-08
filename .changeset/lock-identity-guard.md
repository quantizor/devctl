---
"devctl": minor
---

`devctl lock` can now tell you when a command changed the state it was guarding while a server still held that state open. A `locks` entry may name where the resource lives on disk (`{"name": "d1", "path": ".wrangler/state/v3/d1"}`, alongside the plain `"d1"` form, which keeps working unchanged). With a path declared, `lock` fingerprints that state before and after the command. Under `--no-pause` with a declaring server still running, a change is a `resource-mutated` failure naming the servers to stop and the command to re-run, because the running server holds the old state open and can write its cached pages back over what the command wrote. Under the default paused mode the same change is just a note.

This closes a silent data loss: a migration run under `--no-pause` that wiped and rebuilt a local database reported success while the seeded rows were gone, and nothing in the output distinguished that from a clean run. The check is deliberately modest about its limits, and the contract states them: it flags the risk window rather than the damage, it cannot see state outside the declared path or divergence that never reaches disk, and above 8 MiB it samples a file rather than hashing it whole.
