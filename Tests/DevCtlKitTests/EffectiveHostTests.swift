import Foundation
import Testing

@testable import DevCtlKit

@Suite struct EffectiveHostTests {
    @Test func mainCheckoutEffectiveHostMatchesTheDeclaredOne() {
        let project = EffectiveHostResolver.project(declaredHost: "app.localhost", worktreeHost: nil)
        #expect(project.effective == "app.localhost")
        #expect(project.reason == nil)
        #expect(project.differs == false)
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", overlayHost: nil, project: project, server: "web",
            specHost: "app.localhost")
        #expect(web.effective == "app.localhost")
        #expect(web.reason == nil)
    }

    @Test func linkedWorktreeSwapsTheProjectAndItsFollowingServers() {
        let project = EffectiveHostResolver.project(
            declaredHost: "app.localhost", worktreeHost: "worktree-review.app.localhost")
        #expect(project.effective == "worktree-review.app.localhost")
        #expect(project.reason == .linkedWorktree)
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", overlayHost: nil, project: project, server: "web",
            specHost: "app.localhost")
        #expect(web.declared == "app.localhost")
        #expect(web.effective == "worktree-review.app.localhost")
        #expect(web.reason == .linkedWorktree)
    }

    /** A server that declares its own subdomain keeps it: the spawn path only
        swaps a host that is the project's own. */
    @Test func perServerSubdomainKeepsItsHostInAWorktree() {
        let project = EffectiveHostResolver.project(
            declaredHost: "app.localhost", worktreeHost: "worktree-review.app.localhost")
        let api = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", overlayHost: nil, project: project, server: "api",
            specHost: "api.app.localhost")
        #expect(api.declared == "api.app.localhost")
        #expect(api.effective == "api.app.localhost")
        #expect(api.reason == .serverOverride)
    }

    @Test func overlayHostWinsOverTheWorktreeSwap() {
        let project = EffectiveHostResolver.project(
            declaredHost: "app.localhost", worktreeHost: "worktree-review.app.localhost")
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", overlayHost: "pinned.localhost", project: project,
            server: "web", specHost: "app.localhost")
        #expect(web.effective == "pinned.localhost")
        #expect(web.reason == .localOverlay)
    }

    @Test func aProjectUsingTheDefaultSlugHostStillSwaps() {
        let project = EffectiveHostResolver.project(
            declaredHost: "my-proj.localhost", worktreeHost: "worktree-review.my-proj.localhost")
        let web = EffectiveHostResolver.server(
            defaultSlugHost: "my-proj.localhost", overlayHost: nil, project: project, server: "web",
            specHost: "my-proj.localhost")
        #expect(web.effective == "worktree-review.my-proj.localhost")
        #expect(web.reason == .linkedWorktree)
    }

    /** A per-server override in a main checkout is not a difference to report. */
    @Test func perServerSubdomainOutsideAWorktreeReportsNoReason() {
        let project = EffectiveHostResolver.project(declaredHost: "app.localhost", worktreeHost: nil)
        let api = EffectiveHostResolver.server(
            defaultSlugHost: "app.localhost", overlayHost: nil, project: project, server: "api",
            specHost: "api.app.localhost")
        #expect(api.effective == "api.app.localhost")
        #expect(api.reason == nil)
        #expect(api.differs == false)
    }
}
