import Testing

@testable import DirectaKit

@Suite struct DiscoveryStanzaTests {
    private let tipSuffix =
        " In a git worktree, ensure still manages the server: the host stays the project's usual one and the port may be rebound; the live URL comes from `status` / session context. If context warns about a port conflict, follow that URL or hint; do not edit `devservers.json` just to change ports; do not start an unmanaged `pnpm dev --port`."

    @Test func emptyUsesPlaceholder() {
        #expect(
            DiscoveryStanza.render(serverNames: [])
                == "- This project is registered with directa (devservers.json). Prefer `directa ensure <name>` / `directa status` / `directa logs <name>` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`."
                + tipSuffix)
    }

    @Test func oneNameWiresTheExamples() {
        #expect(
            DiscoveryStanza.render(serverNames: ["myproj"])
                == "- This project is registered with directa (devservers.json). Prefer `directa ensure myproj` / `directa status` / `directa logs myproj` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`."
                + tipSuffix)
    }

    @Test func manyNamesUseTheFirst() {
        #expect(
            DiscoveryStanza.render(serverNames: ["api", "web", "worker"])
                == "- This project is registered with directa (devservers.json). Prefer `directa ensure api` / `directa status` / `directa logs api` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`."
                + tipSuffix)
    }
}
