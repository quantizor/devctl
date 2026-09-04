import Foundation

/** The copy-paste discovery tip `directa hook install` prints so a project can
    teach its agents about directa by pasting one bullet into CLAUDE.md/AGENTS.md.
    A pure string helper: the `directa` CLI target has no unit tests, so the copy
    lives in DirectaKit where it can be asserted. directa never edits those files;
    the human decides whether to paste. */
public enum DiscoveryStanza {
    /** One markdown bullet. With no known server names it uses the `<name>`
        placeholder; with names it wires the first (alphabetically first, matching
        the config's sorted specs) into the `ensure`/`logs` examples. The
        naming/host conventions sentence is constant either way. */
    public static func render(serverNames: [String]) -> String {
        let example = serverNames.first ?? "<name>"
        return "- This project is registered with directa (devservers.json). Prefer `directa ensure \(example)` / `directa status` / `directa logs \(example)` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`. In a git worktree, ensure still manages the server: the host stays the project's usual one and the port may be rebound; the live URL comes from `status` / session context. If context warns about a port conflict, follow that URL or hint; do not edit `devservers.json` just to change ports; do not start an unmanaged `pnpm dev --port`."
    }
}
