import Foundation
import Testing

@testable import DevCtlKit

@Suite struct ConfigProjectionTests {
    /** The strongest guard on the whole field split: a file that goes through
        the validator and back out must describe the same servers. Anything the
        machine derived has to disappear on the way back, or a recovered file
        carries this checkout's incidental state to the next machine. */
    @Test func roundTripThroughValidateKeepsDeclaredFieldsAndDropsDerivedOnes() {
        let original = ProjectFileConfig(
            host: "shop.localhost",
            servers: [
                "api": ProjectFileServer(
                    command: ["bun", "run", "api", "--port", "{port}"],
                    cwd: "packages/api",
                    env: ["LOG_LEVEL": "debug"],
                    healthcheck: HealthCheckSpec(type: .http, url: "/healthz"),
                    host: "api.shop.localhost",
                    port: 8787),
                "web": ProjectFileServer(
                    command: ["bun", "dev"],
                    dependsOn: ["api"],
                    heads: ["admin": "/admin"],
                    port: 3000,
                    waitFor: .started),
            ])
        /** A project directory whose slug is not the declared host, so `host` is a
            real declaration here rather than the loader's default. */
        let project = "/Users/x/code/storefront"
        let view = ProjectConfigLoader.validate(config: original, project: project)
        #expect(view.errors.isEmpty)
        let projected = ConfigProjection.file(host: view.host, project: project, specs: view.specs)
        #expect(projected == original)
        /** And the file it produces means the same thing to the validator, which
            is the property a recovered file actually has to hold. */
        let reloaded = ProjectConfigLoader.validate(config: projected, project: project)
        #expect(reloaded.errors.isEmpty)
        #expect(reloaded.specs == view.specs)
    }

    /** A host equal to the loader's own default is not written back: a recovered
        file stays as quiet as a hand-written one, and still validates the same. */
    @Test func aHostMatchingTheProjectSlugIsOmittedAndStillReloadsIdentically() {
        let original = ProjectFileConfig(
            host: "shop.localhost",
            servers: ["web": ProjectFileServer(command: ["bun", "dev"], port: 3000)])
        let project = "/Users/x/code/shop"
        let view = ProjectConfigLoader.validate(config: original, project: project)
        let projected = ConfigProjection.file(host: view.host, project: project, specs: view.specs)
        #expect(projected.host == nil)
        let reloaded = ProjectConfigLoader.validate(config: projected, project: project)
        #expect(reloaded.host == "shop.localhost")
        #expect(reloaded.specs == view.specs)
    }

    @Test func derivedURLIsNotWrittenButAnExplicitOneSurvives() {
        let derived = ServerSpec(
            command: ["x"], host: "app.localhost", name: "web", port: 3000,
            url: "http://app.localhost:3000/")
        #expect(
            ConfigProjection.server(project: "/p", projectHost: "app.localhost", spec: derived).url
                == nil)
        let explicit = ServerSpec(
            command: ["x"], host: "app.localhost", name: "web", port: 3000,
            url: "https://app.localhost:3000/app")
        #expect(
            ConfigProjection.server(project: "/p", projectHost: "app.localhost", spec: explicit).url
                == "https://app.localhost:3000/app")
    }

    @Test func projectHostIsNotRepeatedOnEveryServerButAnOverrideIs() {
        let follows = ServerSpec(command: ["x"], host: "app.localhost", name: "web")
        #expect(
            ConfigProjection.server(project: "/p", projectHost: "app.localhost", spec: follows).host
                == nil)
        let override = ServerSpec(command: ["x"], host: "api.app.localhost", name: "api")
        #expect(
            ConfigProjection.server(project: "/p", projectHost: "app.localhost", spec: override).host
                == "api.app.localhost")
    }

    /** The ephemeral label belongs to this checkout, so a file recovered from a
        worktree must not carry it to anyone else. */
    @Test func worktreeHostIsNeverWritten() {
        let spec = ServerSpec(
            command: ["x"], host: "worktree-review.app.localhost", name: "web", port: 3000)
        let entry = ConfigProjection.server(
            project: "/p", projectHost: "app.localhost", spec: spec)
        #expect(entry.host == nil)
        #expect(
            ConfigProjection.declarableHost("worktree-review.app.localhost", project: "/p") == nil)
    }

    @Test func defaultSlugHostIsOmittedAndAnExplicitHostIsKept() {
        #expect(ConfigProjection.declarableHost("shop.localhost", project: "/Users/x/code/shop") == nil)
        #expect(
            ConfigProjection.declarableHost("other.localhost", project: "/Users/x/code/shop")
                == "other.localhost")
    }

    @Test func injectedPortEnvAndDevctlHostAreDropped() {
        let spec = ServerSpec(
            command: ["x"], env: ["DEVCTL_HOST": "app.localhost", "KEEP": "1", "PORT": "3000"],
            name: "web", port: 3000)
        #expect(ConfigProjection.declarableEnv(spec) == ["KEEP": "1"])
    }

    @Test func aDeclaredEnvThatIsNotTheInjectedPortSurvives() {
        let spec = ServerSpec(
            command: ["x"], env: ["PORT": "9999"], name: "web", port: 3000)
        #expect(ConfigProjection.declarableEnv(spec) == ["PORT": "9999"])
    }

    @Test func customPortEnvIsDroppedWhenItCarriesTheDeclaredPort() {
        let spec = ServerSpec(
            command: ["x"], env: ["PUBLIC_PORT": "3000"], name: "web", port: 3000,
            portEnv: "PUBLIC_PORT")
        #expect(ConfigProjection.declarableEnv(spec) == nil)
    }

    /** `port` is the declaration. A rebound port lives in `effectivePort`, which
        this projection must never read. */
    @Test func declaredPortIsWrittenNotTheReboundOne() {
        let spec = ServerSpec(command: ["x"], name: "web", port: 3000)
        #expect(ConfigProjection.server(project: "/p", projectHost: "h", spec: spec).port == 3000)
    }

    @Test func absoluteIconBecomesProjectRelativeAndOneOutsideIsDropped() {
        #expect(
            ConfigProjection.relativeIcon("/Users/x/code/shop/assets/icon.png", project: "/Users/x/code/shop")
                == "assets/icon.png")
        #expect(ConfigProjection.relativeIcon("/elsewhere/icon.png", project: "/Users/x/code/shop") == nil)
    }

    @Test func materializedHealthcheckPortAndURLAreDropped() {
        let health = HealthCheckSpec(port: 3000, type: .http, url: "http://app.localhost:3000/")
        let spec = ServerSpec(
            command: ["x"], healthcheck: health, host: "app.localhost", name: "web", port: 3000)
        let entry = ConfigProjection.server(project: "/p", projectHost: "app.localhost", spec: spec)
        #expect(entry.healthcheck?.port == nil)
        #expect(entry.healthcheck?.url == nil)
    }

    @Test func mergeKeepsUnrelatedEntriesAndRefusesAnExistingNameWithoutForce() {
        let existing = ProjectFileConfig(
            servers: [
                "api": ProjectFileServer(command: ["old-api"]),
                "web": ProjectFileServer(command: ["old-web"]),
            ])
        let entry = ProjectFileServer(command: ["new-web"])
        #expect(ConfigProjection.merge(entry: entry, force: false, into: existing, name: "web") == nil)
        let added = ConfigProjection.merge(
            entry: entry, force: false, into: existing, name: "worker")
        #expect(added?.servers["worker"]?.command == ["new-web"])
        #expect(added?.servers["api"]?.command == ["old-api"])
        let replaced = ConfigProjection.merge(
            entry: entry, force: true, into: existing, name: "web")
        #expect(replaced?.servers["web"]?.command == ["new-web"])
        #expect(replaced?.servers["api"]?.command == ["old-api"])
    }
}
