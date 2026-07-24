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
