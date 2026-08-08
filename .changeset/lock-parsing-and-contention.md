---
"devctl": minor
---

`devctl lock` no longer passes its own options to the guarded command. `devctl lock d1 --timeout 300 -- cmd` ran `env --timeout 300 -- cmd` and died with `env: illegal option -- t`, because the resource name ended option parsing and everything after it was captured as the command. The command is now taken from after `--` verbatim, so a nested `--`, a dash option, and an empty string all survive, while a missing terminator or an unknown option is rejected instead of quietly passed through.

A contended `devctl lock` says who holds the resource instead of blocking silently for up to five minutes. It names the holder's pid, how long that run has been going, and which servers it paused or left running, then repeats a still-waiting line while it waits. Silence there reads as a hung gate, and the reflex it invites is killing the run that holds the lock, which is the one making progress. `--acquire-timeout 0` now makes exactly one attempt and fails immediately, which it could not do before: the wait loop never ran its body at a zero budget and failed with a message naming no holder. All of `lock`'s own output moved to stderr, so stdout carries only the guarded command's.
