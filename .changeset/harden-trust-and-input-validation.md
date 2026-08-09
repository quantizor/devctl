---
"devctl": patch
---

A cloned repo's devservers.json can no longer start itself. devctl's rule is that it never acts on a project's committed config until you approve it by running a server there once, but boot restore skipped that check: after a reboot it would bring back a committed server for a project that was never approved. It now honors the same gate every other path does, so an unapproved project's config stays inert until you start it by hand. An explicit `start`, `ensure`, or `up` still records that approval, exactly as before.

`devctl register` now screens a server the same way the config file is screened. Registering a server directly was the one way into the daemon that skipped validation, so a spec `devctl config check` would reject (an out-of-range port, an empty command, a name containing the reserved `::`) could still be registered and then started. It is refused up front now.

`devctl switch` validates the branch's devservers.json before running that branch's lifecycle commands. A config the daemon would refuse to load no longer has its commands handed to the shell anyway, and an empty lifecycle command is now caught by `config check`.

A bad `--grep` pattern can no longer hang the daemon. A regular expression that nests one unbounded repeat inside another (the classic `(a+)+`) makes the engine run for minutes on a single log line; `devctl logs --grep` now rejects that shape before it runs, with a message that names the fix.

devctl no longer hangs waiting on a stuck daemon. A wedged daemon used to leave `devctl` and the menu bar app blocked with no output and no way out; requests now fail in bounded time and point you at `devctl daemon restart`, while a legitimately long `ensure`, `wait`, or group rollout is given the room it needs.

Editing a project's config through the menu bar can only write to a project devctl already tracks, closing a path where a crafted request could have dropped a devservers.json anywhere on disk.
