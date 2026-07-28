import Foundation

/** The copy-paste discovery tip `devctl hook install` prints so a project can
    teach its agents about devctl by pasting one bullet into CLAUDE.md/AGENTS.md.
    A pure string helper: the `devctl` CLI target has no unit tests, so the copy
    lives in DevCtlKit where it can be asserted. devctl never edits those files;
    the human decides whether to paste. */
public enum DiscoveryStanza {
    /** One markdown bullet. With no known server names it uses the `<name>`
        placeholder; with names it wires the first (alphabetically first, matching
        the config's sorted specs) into the `ensure`/`logs` examples. The
        naming/host conventions sentence is constant either way. */
    public static func render(serverNames: [String]) -> String {
        let example = serverNames.first ?? "<name>"
        return "- This project is registered with devctl (devservers.json). Prefer `devctl ensure \(example)` / `devctl status` / `devctl logs \(example)` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`. In a git worktree, ensure still manages the server: the live URL comes from `status` / session context (may be `worktree-*.<preferred>.localhost` on another port). If context warns about a port conflict, follow that URL or hint; do not edit `devservers.json` just to change ports; do not start an unmanaged `pnpm dev --port`."
    }
}
