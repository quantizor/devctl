---
"devctl": patch
---

A head or healthcheck url written as a path (`/admin`) now resolves against the server's own effective base, so it follows a rebind or a worktree host swap. It previously serialized as `//:33334/admin`, a value that reads as a URL in the menu bar, Spotlight, `devctl open`, and agent context, and works in none of them. `config check` now rejects a head or healthcheck url that is neither an absolute URL nor a path, and one written as a path on a server that declares no port or url to resolve it against, so the mistake is caught while it is still cheap.

`devctl up` now spawns with the same spec `ensure` does. It prepared each server's spawn and then re-resolved the supervisor inside its dependency waves, which re-applied the committed config to anything not yet running and discarded the prepared spawn: the rebound port, the worktree host, the substituted `{port}` / `{host}` argv, and the injected environment. In a linked worktree that meant the child bound the committed port while devctl reported the rebind, so `up` in two sibling checkouts left both servers stuck starting. Sibling worktrees now coexist under `up` exactly as they already did under `ensure`.
