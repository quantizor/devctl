import Foundation
import Testing

@testable import DevCtlKit

@Suite struct PortMaterializerTests {
    @Test func injectsPortAndRewritesURL() {
        let spec = ServerSpec(
            command: ["node", "server.js", "--port", "{port}"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            url: "http://app.localhost:3000/"
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3100)
        #expect(next.port == 3100)
        #expect(next.env?["PORT"] == "3100")
        #expect(next.command == ["node", "server.js", "--port", "3100"])
        #expect(next.url == "http://app.localhost:3100/")
    }

    @Test func substitutesHostTokenAndCustomPortEnv() {
        let spec = ServerSpec(
            command: ["echo", "{host}:{port}"],
            host: "old.localhost",
            name: "web",
            port: 3000,
            portEnv: "PUBLIC_PORT",
            url: "http://old.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 4000, effectiveHost: "worktree-x.app.localhost")
        #expect(next.env?["PUBLIC_PORT"] == "4000")
        #expect(next.env?["DEVCTL_HOST"] == "worktree-x.app.localhost")
        #expect(next.command == ["echo", "worktree-x.app.localhost:4000"])
        #expect(next.url == "http://worktree-x.app.localhost:4000/")
        #expect(next.host == "worktree-x.app.localhost")
    }

    @Test func rewritesHeadsAndHealthcheck() {
        let health = HealthCheckSpec(type: .http, url: "http://app.localhost:3000/healthz")
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "http://admin.app.localhost:3000/"],
            healthcheck: health,
            host: "app.localhost",
            name: "web",
            port: 3000
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3333)
        #expect(next.heads?["admin"] == "http://admin.app.localhost:3333/")
        #expect(next.healthcheck?.url == "http://app.localhost:3333/healthz")
    }

    @Test func rewritesTcpHealthcheckPort() {
        let health = HealthCheckSpec(port: 3000, type: .tcp)
        let spec = ServerSpec(
            command: ["serve", "{port}"], healthcheck: health, name: "web", port: 3000)
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 4100)
        #expect(next.healthcheck?.port == 4100)
        #expect(next.command == ["serve", "4100"])
    }

    @Test func rewritesExactHostWhenPreferredChanges() {
        let spec = ServerSpec(
            command: ["serve"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            url: "http://app.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 3100, effectiveHost: "worktree-x.app.localhost")
        #expect(next.url == "http://worktree-x.app.localhost:3100/")
        #expect(next.host == "worktree-x.app.localhost")
    }

    /** Spawn path may already have swapped `spec.host` to the worktree label;
        matchHost keeps committed URL hosts eligible for rewrite. */
    @Test func matchHostRewritesAfterSpecHostAlreadySwapped() {
        let health = HealthCheckSpec(type: .http, url: "http://myproj.localhost:3000/api/health")
        let spec = ServerSpec(
            command: ["serve"],
            healthcheck: health,
            host: "worktree-fix.myproj.localhost",
            name: "myproj",
            port: 3000,
            url: "http://myproj.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 3742, effectiveHost: spec.host,
            matchHost: "myproj.localhost")
        #expect(next.url == "http://worktree-fix.myproj.localhost:3742/")
        #expect(next.healthcheck?.url == "http://worktree-fix.myproj.localhost:3742/api/health")
    }

    @Test func relativeHeadResolvesAgainstTheServerBase() {
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "/admin"],
            host: "app.localhost",
            name: "web",
            port: 33_334
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 33_334)
        #expect(next.heads?["admin"] == "http://app.localhost:33334/admin")
    }

    @Test func relativeHeadFollowsAReboundPortAndAWorktreeHost() {
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "/admin", "docs": "/docs/index.html"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            url: "http://app.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 3742, effectiveHost: "worktree-x.app.localhost",
            matchHost: "app.localhost")
        #expect(next.heads?["admin"] == "http://worktree-x.app.localhost:3742/admin")
        #expect(next.heads?["docs"] == "http://worktree-x.app.localhost:3742/docs/index.html")
    }

    @Test func relativeHeadKeepsItsQueryAndFragment() {
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "/admin?tab=1#top"],
            host: "app.localhost",
            name: "web",
            port: 3000
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3000)
        #expect(next.heads?["admin"] == "http://app.localhost:3000/admin?tab=1#top")
    }

    @Test func relativeHealthcheckURLResolvesAgainstTheBase() {
        let health = HealthCheckSpec(type: .http, url: "/healthz")
        let spec = ServerSpec(
            command: ["serve"], healthcheck: health, host: "app.localhost", name: "web", port: 3000)
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3000)
        #expect(next.healthcheck?.url == "http://app.localhost:3000/healthz")
    }

    /** A path-only string parses as URLComponents with a nil host, and setting a
        port on a hostless component set serializes an empty authority
        (`//:3000/admin`). Returning nil is what hands the caller its
        relative-resolution and token-substitution fallbacks. */
    @Test func hostlessURLIsNeverStampedWithAPort() {
        #expect(PortMaterializer.rewriteURL("/admin", port: 3000, host: "app.localhost") == nil)
        #expect(PortMaterializer.rewriteURL("admin", port: 3000, host: nil) == nil)
    }

    @Test func relativeHeadWithNoBaseIsLeftAlone() {
        let spec = ServerSpec(command: ["serve"], heads: ["admin": "/admin"], name: "web")
        let next = PortMaterializer.materialize(spec: spec, effectivePort: nil)
        #expect(next.heads?["admin"] == "/admin")
    }
}

@Suite struct LocalOverlayTests {
    @Test func mergesPortAndEnv() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "devctl-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let overlay = LocalOverlayFile(
            servers: [
                "web": LocalOverlayServer(env: ["FOO": "bar"], port: 4100)
            ])
        let data = try JSONCoding.encoder().encode(overlay)
        try data.write(to: LocalOverlay.overlayURL(project: dir.path))
        let loaded = LocalOverlay.load(project: dir.path)
        #expect(loaded?.servers?["web"]?.port == 4100)
        let base = ServerSpec(
            command: ["serve"], env: ["FOO": "old", "KEEP": "1"], name: "web", port: 3000)
        let merged = LocalOverlay.apply(
            spec: base, overlay: loaded?.servers?["web"], project: dir.path)
        #expect(merged.port == 4100)
        #expect(merged.env?["FOO"] == "bar")
        #expect(merged.env?["KEEP"] == "1")
    }
}

@Suite struct CheckoutIdentityTests {
    @Test func sanitizeLabel() {
        #expect(CheckoutIdentity.sanitizeLabel("Fix Checkout Hosts") == "fix-checkout-hosts")
        #expect(CheckoutIdentity.sanitizeLabel("app_v2") == "app-v2")
    }

    @Test func siblingPortCandidateStaysInEphemeralRange() {
        let port = CheckoutIdentity.siblingPortCandidate(declared: 3000, project: "/tmp/proj-a")
        #expect(port >= 1024)
        #expect(port <= 65_000)
        #expect(port != 3000)
    }

    @Test func preferredSubdomainFromCommittedHost() {
        #expect(
            CheckoutIdentity.preferredSubdomain(
                project: "/tmp/whatever", committedHost: "myproj.localhost") == "myproj")
        #expect(
            CheckoutIdentity.preferredSubdomain(
                project: "/tmp/whatever", committedHost: "api.myproj.localhost") == "myproj")
    }
}
