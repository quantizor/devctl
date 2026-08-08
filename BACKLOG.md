# devctl backlog

Open work only; entries are removed by the change that resolves them.

- No way to produce or recover a `devservers.json`: it is hand-authored, `register` writes the machine registry only, and a gitignored per-machine file (now a documented posture) is unrecoverable if the machine goes. Wants either a `devctl config init` that emits a valid file from flags or from the running registry, or a `register --write` that appends to the file rather than the registry. design.md described `--write` as if it shipped; it does not.
- Orphan re-adoption without the bounce: after a daemon crash, re-adopt live orphan servers (pid + start-time match, resume spool tailing) instead of group-kill + restart. Blocked on: exit codes are unknowable for non-children; needs a design for degraded forensics.
- Reverse proxy on :80/:443 routing by host signature, making ports disappear from `*.localhost` URLs (Valet/Herd territory). Ephemeral `worktree-*.<preferred>.localhost` hosts are the unprivileged addressing half; the proxy would drop ports from URLs entirely.
- MenuBarExtraAccess (orchetect) if `.window` presentation quirks bite in practice.
- Populate Apple Developer ID + App Store Connect API secrets for `.github/workflows/release-dmg.yml` (and a Homebrew tap) so the Release→DMG dispatch can notarize on Actions; until then, mint locally (`SIGN_IDENTITY=… make dmg` + `scripts/notarize.sh` + `gh release upload`). `v1.3.0` already has a stapled DMG from the local path.
- App Intents / Shortcuts wrappers over the existing `DeepLink` verbs (`open`, `ensure`, `stop`, `why`) for Siri / Gemini-Siri and Control Center. The `devctl://` URL table and `DeepLinkRunner` are the shared surface; intents should call the runner, not reimplement dispatch. Also the next plausible path for Spotlight ranking (IndexedEntity) once Core Spotlight levers are exhausted.
- swift-subprocess 0.5 occasionally fatals in its kqueue AsyncIO cleanup at process exit ("Failed to close kqueue fds: Bad file descriptor"), seen once under parallel test load; harmless to the long-lived daemon but track against upstream releases (pinned revision in Package.swift).
- Lock-release false `crashed` (2026-07-25, a pnpm monorepo: healthy then exit 0 in ~230ms): unreproducible on fixture rapid acquire/release (N=20), on the grandchild fixture, and on live `lock` cycles against a real project (2026-07-28). Resume now settles until the PortClaim is free or refuses to spawn dirty. Reopen with a failing repro that names exiting pid vs resumed pid before changing the exit classifier.
- Spotlight thumbnails: confirm config icons render in the real Spotlight UI. Within-app ranking levers are maxed (lastUsed preserved across sync, incremental index updates, live/pinned rankingHint, alternateNames). Outranking filesystem / Cursor Top Hits remains an Apple ceiling; do not chase without a new system API.
- Machine-wide resource lock opt-in: locks are already path-scoped (`canonicalPath::resource`) and pause only that path's declarers. A rare shared system resource (one Docker Postgres, a fixed system daemon) may still want an explicit machine-wide scope so two projects serialize. Not the Cloudflare worktree pause case (that was misread against path-scoped keys); defer until a concrete cross-project shared-resource incident.
- `IntegrationTests` is a single `placeholder()` while `docs/design.md` promises a real end-to-end suite there (port-conflict from a second project, concurrent double-ensure). Those now live in `scripts/smoke.sh` and unit suites; either build the integration target out or retire the promise in the design doc.
- A restarting daemon is indistinguishable from a dead one for the length of `recoverAtStartup`, which is seconds when there is real state to restore. The listener only reaches `.ready` after restore, and the socket is unlinked in `ControlServer.init`, so clients get `daemon-unreachable` with ENOENT and nothing that says "starting". Moving the unlink later only changes the errno, since the daemon is unreachable either way: the fix is to answer during restore (bind early and reply "starting" to everything, or write a state file clients can read) so `devctl daemon status` can say restoring rather than down. Wanted because install/restart bounce servers, and an agent polling through that window sees a daemon that looks gone.
- Split `CLI.swift`: every command struct lives in that one file, which is past the size where splitting is worth asking about. A structure decision, not drift; the codebase map describes the current layout.
- `lock` mis-parses its own options after the resource: `devctl lock d1 --timeout 300 -- <cmd>` passed `--timeout` through to the command, which failed with `env: illegal option -- t`. The same call without `--timeout` worked. Either the option has to precede the resource (undocumented, and `--help` lists it after `<resource>`) or the parser is leaking pre-`--` options into the command vector. A stray flag reaching the command is a silent behavior change in the worst case, not just a usage error.
- A relative `heads` entry in `devservers.json` renders a malformed URL rather than resolving against the server's own base. `"admin": "/admin"` on a port-33334 server produced `//:33334/admin`, and `devctl config check` reported zero errors and zero warnings on that config. Either resolve a relative head against the computed URL (which is what a reader writing `/admin` means) or reject it at `config check`, where the mistake is still cheap. Silently emitting a broken URL is the one option that helps nobody.
- Worktree host prefixing is invisible until a server starts. A checkout under a git worktree gets `worktree-<dir>.` prepended to the configured host, so the effective origin is not the one in `devservers.json` and nothing before `ensure` says so. That matters beyond cosmetics: any origin-pinned config the app itself reads (an auth callback URL, a CORS allow-list, an API key's referrer restriction) is now wrong, and the failure surfaces as a broken app rather than as a host mismatch. `config check` could print the effective host for the current directory.

## `lock --no-pause` is not enough when the command deletes the locked state

A session wiped a project's local database directory to re-run migrations from
scratch, under `devctl lock d1 --no-pause`. The lock serialized access, but the
dev server kept the file open across the deletion and flushed its cached pages
back over the freshly migrated file. The migration reported success, the ledger
recorded every file as applied, and the seeded rows were gone. Three separate
wrong diagnoses followed before reading the sqlite file's raw bytes settled it,
and one of those wrong diagnoses got as far as a new guardrail before being
disproved.

`--no-pause` is documented as "the server tolerates staying up", which reads as a
property of the *server*. The property that actually matters is a property of the
*command*: whether it mutates the resource in place (fine) or removes and
recreates it (not fine, the open handle wins).

Worth considering:

- Refuse `--no-pause` when the command line touches the locked resource's own
  state path with a removing verb (`rm`, `mv`, `rmdir`), or at least warn.
- Or make `lock` report, on completion, that the resource's backing file changed
  identity (inode/hash) while a holder was up, which is the observable tell.

Either turns a silent data loss into a loud refusal. Right now nothing in the
output distinguishes "migrated and seeded" from "migrated, seeded, and clobbered".
