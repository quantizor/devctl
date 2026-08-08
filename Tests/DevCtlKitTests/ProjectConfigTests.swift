import Foundation
import Testing

@testable import DevCtlKit

@Suite struct ProjectConfigTests {
    @Test func specsDeriveHostAndURL() {
        let config = ProjectFileConfig(
            servers: [
                "api": ProjectFileServer(command: ["bun", "api"], port: 8787),
                "web": ProjectFileServer(command: ["bun", "dev"], dependsOn: ["api"], port: 3000),
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/Users/x/code/My Proj")
        #expect(view.errors.isEmpty)
        #expect(view.host == "my-proj.localhost")
        let web = view.specs.first { $0.name == "web" }
        #expect(web?.url == "http://my-proj.localhost:3000/")
    }

    /** An http healthcheck with no url falls back to a TCP probe, so the server
        can report healthy while its HTTP layer was never checked. The config has
        to say so, since nothing downstream can tell the fallback from intent. */
    @Test func httpHealthcheckWithoutURLWarns() {
        let config = ProjectFileConfig(
            servers: [
                "typo": ProjectFileServer(
                    command: ["x"], healthcheck: HealthCheckSpec(type: .http), port: 5000),
                "ok": ProjectFileServer(
                    command: ["x"],
                    healthcheck: HealthCheckSpec(type: .http, url: "http://x.localhost:5001/"),
                    port: 5001),
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.errors.isEmpty)
        let warned = view.warnings.filter { $0.contains("healthcheck type is http") }
        #expect(warned.count == 1)
        #expect(warned.first?.contains("'typo'") == true)
    }

    @Test func explicitHostAndPerServerOverride() {
        let config = ProjectFileConfig(
            host: "shop.localhost",
            servers: [
                "api": ProjectFileServer(command: ["x"], host: "api.shop.localhost", port: 4000)
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.specs.first?.url == "http://api.shop.localhost:4000/")
    }

    @Test func validationCatchesCyclesUnknownDepsAndPortDupes() {
        let config = ProjectFileConfig(
            servers: [
                "a": ProjectFileServer(command: ["x"], dependsOn: ["b"], port: 3000),
                "b": ProjectFileServer(command: ["x"], dependsOn: ["a"], port: 3000),
                "c": ProjectFileServer(command: ["x"], dependsOn: ["ghost"]),
                "d": ProjectFileServer(command: []),
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.errors.contains { $0.contains("cycle") })
        #expect(view.errors.contains { $0.contains("unknown server 'ghost'") })
        #expect(view.errors.contains { $0.contains("command is empty") })
        #expect(view.warnings.contains { $0.contains("both declare port 3000") })
    }

    @Test func bareLoopbackHostsWarnButDoNotFail() {
        let config = ProjectFileConfig(
            host: "localhost",
            servers: [
                "api": ProjectFileServer(command: ["x"], host: "127.0.0.1", port: 4000),
                "web": ProjectFileServer(command: ["x"], url: "http://localhost:3000/"),
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/Users/x/code/My Proj")
        #expect(view.errors.isEmpty)
        #expect(
            view.warnings.contains {
                $0 == "host 'localhost' is a bare loopback address; prefer 'my-proj.localhost' so each project keeps an isolated browser origin"
            })
        #expect(
            view.warnings.contains {
                $0 == "server 'api': host '127.0.0.1' is a bare loopback address; prefer a 'my-proj.localhost' subdomain"
            })
        #expect(
            view.warnings.contains {
                $0 == "server 'web': url 'http://localhost:3000/' points at a bare loopback host; prefer 'my-proj.localhost'"
            })
    }

    @Test func subdomainLocalhostHostsDoNotWarn() {
        let config = ProjectFileConfig(
            host: "shop.localhost",
            servers: [
                "api": ProjectFileServer(command: ["x"], host: "api.shop.localhost", port: 4000),
                "web": ProjectFileServer(command: ["x"], port: 3000),
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.warnings.allSatisfy { !$0.contains("loopback") })
    }

    @Test func relativeHeadWithABaseIsAccepted() {
        let config = ProjectFileConfig(
            servers: ["web": ProjectFileServer(command: ["x"], heads: ["admin": "/admin"], port: 3000)])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.errors.isEmpty)
        #expect(view.warnings.allSatisfy { !$0.contains("head") })
    }

    @Test func relativeHeadWithNoPortOrURLIsAnError() {
        let config = ProjectFileConfig(
            servers: ["web": ProjectFileServer(command: ["x"], heads: ["admin": "/admin"])])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(
            view.errors.contains {
                $0 == "server 'web': head 'admin' is the path '/admin' but the server declares no port or url to resolve it against; give the server a port, or write the head as an absolute URL"
            })
    }

    @Test func headThatIsNeitherAbsoluteNorRootedIsAnError() {
        let config = ProjectFileConfig(
            servers: ["web": ProjectFileServer(command: ["x"], heads: ["admin": "admin"], port: 3000)])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(
            view.errors.contains {
                $0 == "server 'web': head 'admin' is 'admin', which is neither an absolute URL nor a path starting with '/'; write 'http://host:port/admin' or '/admin'"
            })
    }

    @Test func emptyHeadIsAnError() {
        let config = ProjectFileConfig(
            servers: ["web": ProjectFileServer(command: ["x"], heads: ["admin": ""], port: 3000)])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.errors.contains { $0 == "server 'web': head 'admin' is empty" })
    }

    @Test func bareLoopbackHeadWarns() {
        let config = ProjectFileConfig(
            host: "shop.localhost",
            servers: [
                "web": ProjectFileServer(
                    command: ["x"], heads: ["admin": "http://localhost:3000/admin"], port: 3000)
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/Users/x/code/My Proj")
        #expect(view.errors.isEmpty)
        #expect(
            view.warnings.contains {
                $0 == "server 'web': head 'admin' points at a bare loopback host; prefer 'my-proj.localhost'"
            })
    }

    /** `{host}` / `{port}` are legal input to materialization, so their shape
        cannot be judged before the effective values are known. */
    @Test func tokenHeadIsLeftToMaterialization() {
        let config = ProjectFileConfig(
            servers: [
                "web": ProjectFileServer(
                    command: ["x"], heads: ["admin": "http://{host}:{port}/admin"], port: 3000)
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(view.errors.isEmpty)
        #expect(view.warnings.allSatisfy { !$0.contains("head") })
    }

    @Test func relativeHealthcheckURLWithNoBaseIsAnError() {
        let config = ProjectFileConfig(
            servers: [
                "web": ProjectFileServer(
                    command: ["x"], healthcheck: HealthCheckSpec(type: .http, url: "/healthz"))
            ])
        let view = ProjectConfigLoader.validate(config: config, project: "/p")
        #expect(
            view.errors.contains {
                $0.contains("healthcheck url") && $0.contains("no port or url to resolve it against")
            })
    }

    @Test func parseErrorIsActionable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "devctl-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "servers": {"web": {"port": 3000}}}"#.utf8)
            .write(to: dir.appending(path: "devservers.json"))
        do {
            _ = try ProjectConfigLoader.load(project: dir.path)
            Issue.record("expected config-invalid")
        } catch let error as WireError {
            #expect(error.code == .configInvalid)
            #expect(error.message.contains("command"))
        }
    }
}

@Suite struct DependencyGraphTests {
    private func spec(_ name: String, deps: [String] = []) -> ServerSpec {
        ServerSpec(command: ["x"], dependsOn: deps.isEmpty ? nil : deps, name: name)
    }

    @Test func wavesRespectDependencies() {
        let result = DependencyGraph.waves(specs: [
            spec("web", deps: ["api", "worker"]),
            spec("api", deps: ["db"]),
            spec("worker", deps: ["db"]),
            spec("db"),
        ])
        #expect(result == .success([["db"], ["api", "worker"], ["web"]]))
    }

    @Test func cycleIsReported() {
        let result = DependencyGraph.waves(specs: [
            spec("a", deps: ["b"]),
            spec("b", deps: ["a"]),
        ])
        #expect(result == .cycle(["a", "b"]))
    }

    @Test func unknownDependenciesAreIgnoredInOrdering() {
        /** Validation reports the unknown name; ordering just skips it. */
        let result = DependencyGraph.waves(specs: [spec("web", deps: ["ghost"])])
        #expect(result == .success([["web"]]))
    }
}
