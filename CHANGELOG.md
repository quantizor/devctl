# Changelog

## 1.4.0
### Minor Changes



- [#12](https://github.com/quantizor/devctl/pull/12) [`f5831ac`](https://github.com/quantizor/devctl/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - `devctl config init` writes a devservers.json from the servers the daemon already knows, which is the way back from losing one. The file is routinely gitignored per machine and nothing could regenerate it, so a lost or destroyed config meant retyping every server by hand. What it writes is deliberately portable: an effective or rebound port, a worktree-derived host, a materialized url, an absolute icon path, and the port and host variables devctl injects are all dropped, so a file recovered inside a linked worktree is still correct on someone else's machine. `--dry-run` shows the content without touching disk, and an existing file is refused unless `--force`. `devctl register --write` appends one server to the file, leaving every other entry alone.
  
  `devctl config check` now reports the host a start would actually use when it differs from the declared one. A linked worktree gets an ephemeral host, so any origin the app itself pins (an auth callback URL, a CORS allow list, an API key referrer restriction) was already wrong with nothing saying so until the app broke.
  
  `devctl stop` on a server that declares a resource points at `devctl lock`, which gets exclusive access without a bounce, and `ServerStatus` carries the server's `locks` so the same fact reaches `--json` consumers. The session context block names `devctl lock` as the way to exclusive access, and its invitation to report devctl friction now says to describe the problem generically rather than naming the project, since that backlog lives outside it.


- [#13](https://github.com/quantizor/devctl/pull/13) [`5f24f46`](https://github.com/quantizor/devctl/commit/5f24f4634d3ac5ea4d72fc58286f89fe85f3976b) - `devctl lock` can now tell you when a command changed the state it was guarding while a server still held that state open. A `locks` entry may name where the resource lives on disk (`{"name": "d1", "path": ".wrangler/state/v3/d1"}`, alongside the plain `"d1"` form, which keeps working unchanged). With a path declared, `lock` fingerprints that state before and after the command. Under `--no-pause` with a declaring server still running, a change is a `resource-mutated` failure naming the servers to stop and the command to re-run, because the running server holds the old state open and can write its cached pages back over what the command wrote. Under the default paused mode the same change is just a note.
  
  This closes a silent data loss: a migration run under `--no-pause` that wiped and rebuilt a local database reported success while the seeded rows were gone, and nothing in the output distinguished that from a clean run. The check is deliberately modest about its limits, and the contract states them: it flags the risk window rather than the damage, it cannot see state outside the declared path or divergence that never reaches disk, and above 8 MiB it samples a file rather than hashing it whole.


- [#13](https://github.com/quantizor/devctl/pull/13) [`5f24f46`](https://github.com/quantizor/devctl/commit/5f24f4634d3ac5ea4d72fc58286f89fe85f3976b) - `devctl lock` no longer passes its own options to the guarded command. `devctl lock d1 --timeout 300 -- cmd` ran `env --timeout 300 -- cmd` and died with `env: illegal option -- t`, because the resource name ended option parsing and everything after it was captured as the command. The command is now taken from after `--` verbatim, so a nested `--`, a dash option, and an empty string all survive, while a missing terminator or an unknown option is rejected instead of quietly passed through.
  
  A contended `devctl lock` says who holds the resource instead of blocking silently for up to five minutes. It names the holder's pid, how long that run has been going, and which servers it paused or left running, then repeats a still-waiting line while it waits. Silence there reads as a hung gate, and the reflex it invites is killing the run that holds the lock, which is the one making progress. `--acquire-timeout 0` now makes exactly one attempt and fails immediately, which it could not do before: the wait loop never ran its body at a zero budget and failed with a message naming no holder. All of `lock`'s own output moved to stderr, so stdout carries only the guarded command's.


- [#11](https://github.com/quantizor/devctl/pull/11) [`ae6a118`](https://github.com/quantizor/devctl/commit/ae6a11804fae863f8b3aff02b0443df02c1a75b3) - Port conflicts now announce themselves at the first surface that can see them. `why` names the server and project holding a stopped server's port instead of answering only "not running (stopped)", and the machine-wide status sweep carries the same annotation, so the menu bar app and `doctor` see it too. `doctor` gains a `port-collision` finding for two unrelated projects that declare one port, which the host-keyed signature table could never report because the hostnames differ while the bind does not; sibling worktrees stay excluded since they rebind by design. A server whose healthcheck is answered by another supervised server now fails with `portConflict.state: "foreign"` rather than reporting healthy while serving nothing, and a port held by this server and a stranger at once is reported as `"shared"`. A listener outside the process tree that cannot be attributed to a managed server is annotated but left running, because a container-backed or daemonizing server keeps its socket in a process devctl never parented. An unavailable `lsof` can never fail a healthy server, since an empty result is not treated as evidence.
  
  `config check` warns when a healthcheck declares `type: http` with no `url`, which silently falls back to a TCP probe: a mistyped key otherwise yields a server reporting healthy while its HTTP layer was never checked. `doctor` also stops calling a listener unmanaged when another supervised server is the one holding the port.
  
  `devctl daemon status --json` now reports `reachable`. Every other command's hint points at this one, and it previously answered `{"launchd": "state = running"}` with exit 0 when nothing was listening, so a script or agent following the hint was told things were fine. `launchd: running` only means a job is loaded, never that the socket accepts.


- [#10](https://github.com/quantizor/devctl/pull/10) [`b7bc910`](https://github.com/quantizor/devctl/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Lock resume waits until claimed ports are free before re-ensuring, so a pause no longer races a dirty bind. Composite servers declare a port span or named subports so sibling worktrees rebind a whole claim block (relative offsets move, absolute ports stay singleton), and `devctl why` keeps the refusal lines from the last run across ensure retries instead of going blank on exit 0.



- [#10](https://github.com/quantizor/devctl/pull/10) [`b7bc910`](https://github.com/quantizor/devctl/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Two git worktrees of one repo can both run under supervision without editing `devservers.json`. When a sibling checkout already holds the committed port, `ensure` auto-rebinds to a free port, keeps the main origin on the declared host, and gives the worktree an ephemeral `worktree-*.<preferred>.localhost` URL; unrelated projects and unmanaged listeners still get a loud `port-held` naming the holder. Session context and ensure/status JSON warn about latent and rebound conflicts so agents use the live URL, and `lock --no-pause` lets a harness take the mutex without stopping the server it reuses. Discarding a worktree stops its servers and frees the ephemeral host without a manual doctor pass. Bad-state servers in the session-start block still lead with a `devctl why` recommendation and a stderr line count, never the server's own output.


### Patch Changes



- [#12](https://github.com/quantizor/devctl/pull/12) [`f5831ac`](https://github.com/quantizor/devctl/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - A server that loses its port to another supervised server now names that server the way a person reads it. The message carried devctl's internal server id, so it read `managed server '/Users/me/code/proj::web'`, and it now says `'web' in /Users/me/code/proj` with a `devctl stop` command that can be run as printed.



- [#10](https://github.com/quantizor/devctl/pull/10) [`b7bc910`](https://github.com/quantizor/devctl/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Installing or restarting the daemon no longer floods the menu bar with false "server crashed" alerts for the expected bounce, and boot restore finishes before clients connect so upgrade re-ensure does not race and leave servers on a bad port. `devctl why` also diagnoses file-backed projects correctly, and an unexpected server exit tears down leftover child processes so the next ensure is not blocked by stale locks.



- [#12](https://github.com/quantizor/devctl/pull/12) [`f5831ac`](https://github.com/quantizor/devctl/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - A head or healthcheck url written as a path (`/admin`) now resolves against the server's own effective base, so it follows a rebind or a worktree host swap. It previously serialized as `//:33334/admin`, a value that reads as a URL in the menu bar, Spotlight, `devctl open`, and agent context, and works in none of them. `config check` now rejects a head or healthcheck url that is neither an absolute URL nor a path, and one written as a path on a server that declares no port or url to resolve it against, so the mistake is caught while it is still cheap.
  
  `devctl up` now spawns with the same spec `ensure` does. It prepared each server's spawn and then re-resolved the supervisor inside its dependency waves, which re-applied the committed config to anything not yet running and discarded the prepared spawn: the rebound port, the worktree host, the substituted `{port}` / `{host}` argv, and the injected environment. In a linked worktree that meant the child bound the committed port while devctl reported the rebind, so `up` in two sibling checkouts left both servers stuck starting. Sibling worktrees now coexist under `up` exactly as they already did under `ensure`.

## 1.3.0
### Minor Changes



- [#8](https://github.com/quantizor/devctl/pull/8) [`e503e93`](https://github.com/quantizor/devctl/commit/e503e937766af58499f2ff108da04142b28a8ff1) - Ship a DMG installer that places the app in Applications and registers the Login Items agent, keep resource locks across a daemon crash so paused servers resume, and rebind the helper after ad-hoc upgrades so the daemon returns in seconds instead of stalling on a codesign throttle.

All notable changes to this project are documented here. Releases are tagged
`vX.Y.Z` on GitHub (same scheme Changesets uses for this root package).

## 1.2.0

### Minor Changes

- [#4](https://github.com/quantizor/devctl/pull/4) [`40d3e97`](https://github.com/quantizor/devctl/commit/40d3e9741f79b110e08d1ede6515c1ec4636e3c9) - Add Cursor sessionStart harness (`devctl hook install --harness cursor`) so Agent sessions get live `<devctl-servers>` context.
- [#6](https://github.com/quantizor/devctl/pull/6) [`d5ebe80`](https://github.com/quantizor/devctl/commit/d5ebe80704003103c90a8693a53ea5ae044ca840) - Open servers and run lifecycle verbs via `devctl://` URLs (menu bar app + `devctl link` / `devctl x-url`), with unified logging under subsystem `dev.quantizor.devctl`.

### Patch Changes

- [#6](https://github.com/quantizor/devctl/pull/6) [`46ab7b1`](https://github.com/quantizor/devctl/commit/46ab7b17bcf30cbbd336b7e3d7257b0b76586779) - Warn in `config check` when a host or url uses bare `localhost` / `127.0.0.1` instead of a `<slug>.localhost` origin.
- [#6](https://github.com/quantizor/devctl/pull/6) [`4695414`](https://github.com/quantizor/devctl/commit/4695414a2995b0d6f0d3413a1c09c8ecd4e24903) - After `hook install`, print a one-bullet CLAUDE.md / AGENTS.md discovery tip for the project (paste-only; never auto-edits those files).
- [#6](https://github.com/quantizor/devctl/pull/6) [`67d83e7`](https://github.com/quantizor/devctl/commit/67d83e7a569a55735f040ec20b2cf6cc5e3ad4c2) - Restore config-defined servers after reboot and `daemon install` upgrades (merged config+registry recover; install re-ensures like restart).
- [#6](https://github.com/quantizor/devctl/pull/6) [`631a50f`](https://github.com/quantizor/devctl/commit/631a50fe59a6b620eb31d084a6357026e7353354) - Spotlight entries use `<project> · <head>` titles with a `devctl · <url>` subtitle for clearer discovery.

## 1.1.0

### Patch Changes

- Fixed a health check issue with some dev servers that primarily communicate over IPv6.
- Many design improvements.
- Keyboard navigation.
- Sorting & Filtering.

## 1.0.0

Initial public release.
