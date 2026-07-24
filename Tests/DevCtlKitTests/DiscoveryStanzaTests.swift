import Testing

@testable import DevCtlKit

@Suite struct DiscoveryStanzaTests {
    @Test func emptyUsesPlaceholder() {
        #expect(
            DiscoveryStanza.render(serverNames: [])
                == "- This project is registered with devctl (devservers.json). Prefer `devctl ensure <name>` / `devctl status` / `devctl logs <name>` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`.")
    }

    @Test func oneNameWiresTheExamples() {
        #expect(
            DiscoveryStanza.render(serverNames: ["myproj"])
                == "- This project is registered with devctl (devservers.json). Prefer `devctl ensure myproj` / `devctl status` / `devctl logs myproj` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`.")
    }

    @Test func manyNamesUseTheFirst() {
        #expect(
            DiscoveryStanza.render(serverNames: ["api", "web", "worker"])
                == "- This project is registered with devctl (devservers.json). Prefer `devctl ensure api` / `devctl status` / `devctl logs api` over launching the server directly. Name servers after the project (not `web`); use `<project>.localhost` hosts, not bare `localhost`.")
    }
}
