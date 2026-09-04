import Foundation
import Testing

@testable import DirectaKit

@Suite struct EffectiveHostTests {
    @Test func aServerWithoutOverridesMatchesTheDeclaredHost() {
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", declaredHost: "app.localhost", overlayHost: nil,
            server: "web", specHost: "app.localhost")
        #expect(web.declared == "app.localhost")
        #expect(web.effective == "app.localhost")
        #expect(web.reason == nil)
        #expect(web.differs == false)
    }

    /** A spec with no host of its own follows the project's declared host. */
    @Test func aHostlessServerFollowsTheProject() {
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", declaredHost: "app.localhost", overlayHost: nil,
            server: "web", specHost: nil)
        #expect(web.declared == "app.localhost")
        #expect(web.effective == "app.localhost")
        #expect(web.reason == nil)
    }

    @Test func overlayHostWins() {
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", declaredHost: "app.localhost",
            overlayHost: "pinned.localhost", server: "web", specHost: "app.localhost")
        #expect(web.declared == "app.localhost")
        #expect(web.effective == "pinned.localhost")
        #expect(web.reason == .localOverlay)
        #expect(web.differs)
    }

    /** A server that declares its own subdomain keeps it. The difference is
        the author's, not one directa derived, so it carries no reason. */
    @Test func perServerSubdomainKeepsItsHostWithoutAReason() {
        let api = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", declaredHost: "app.localhost", overlayHost: nil,
            server: "api", specHost: "api.app.localhost")
        #expect(api.declared == "api.app.localhost")
        #expect(api.effective == "api.app.localhost")
        #expect(api.reason == nil)
        #expect(api.differs == false)
    }

    /** A worktree changes nothing: the declared host is used unchanged (the
        worktree name surfaces as a display value instead), and a spec filled
        with the default slug host is as good as an explicit declaration. */
    @Test func defaultSlugHostIsTreatedAsTheProjectHost() {
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "my-proj.localhost", declaredHost: "my-proj.localhost",
            overlayHost: nil, server: "web", specHost: "my-proj.localhost")
        #expect(web.effective == "my-proj.localhost")
        #expect(web.reason == nil)

        let declared = EffectiveHostResolver.server(
            defaultSlugHost: "my-proj.localhost", declaredHost: "custom.localhost",
            overlayHost: nil, server: "web", specHost: "my-proj.localhost")
        #expect(declared.declared == "my-proj.localhost")
        #expect(declared.effective == "custom.localhost")
        #expect(declared.reason == nil)
        #expect(declared.differs)
    }
}
