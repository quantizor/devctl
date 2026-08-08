---
"devctl": minor
---

`devctl config init` writes a devservers.json from the servers the daemon already knows, which is the way back from losing one. The file is routinely gitignored per machine and nothing could regenerate it, so a lost or destroyed config meant retyping every server by hand. What it writes is deliberately portable: an effective or rebound port, a worktree-derived host, a materialized url, an absolute icon path, and the port and host variables devctl injects are all dropped, so a file recovered inside a linked worktree is still correct on someone else's machine. `--dry-run` shows the content without touching disk, and an existing file is refused unless `--force`. `devctl register --write` appends one server to the file, leaving every other entry alone.

`devctl config check` now reports the host a start would actually use when it differs from the declared one. A linked worktree gets an ephemeral host, so any origin the app itself pins (an auth callback URL, a CORS allow list, an API key referrer restriction) was already wrong with nothing saying so until the app broke.

`devctl stop` on a server that declares a resource points at `devctl lock`, which gets exclusive access without a bounce, and `ServerStatus` carries the server's `locks` so the same fact reaches `--json` consumers. The session context block names `devctl lock` as the way to exclusive access, and its invitation to report devctl friction now says to describe the problem generically rather than naming the project, since that backlog lives outside it.
