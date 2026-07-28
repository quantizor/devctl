import Foundation
import Testing

@testable import DevCtlKit

@Suite struct PortClaimTests {
    @Test func spanOnlyClaimsConsecutiveBlock() throws {
        let spec = ServerSpec(
            command: ["serve"], name: "web", port: 3000, portEnv: "PUBLIC_PORT", portSpan: 4)
        let resolved = PortClaim.resolve(spec: spec, effectivePort: 3100)
        let claim = try #require(resolved.claim)
        #expect(resolved.error == nil)
        #expect(claim.primary == 3100)
        #expect(claim.relative == [3100, 3101, 3102, 3103])
        #expect(claim.injections["PUBLIC_PORT"] == 3100)
        #expect(claim.named.isEmpty)
    }

    @Test func namedRelativeAndAbsolute() throws {
        let spec = ServerSpec(
            command: ["serve"],
            name: "web",
            port: 3000,
            portEnv: "PUBLIC_PORT",
            ports: [
                "cms": SecondaryPort(env: "CMS_PORT", offset: 1),
                "metrics": SecondaryPort(env: "METRICS_PORT", port: 9090),
            ])
        let claim = try #require(PortClaim.resolve(spec: spec, effectivePort: 4000).claim)
        #expect(claim.relative == [4000, 4001])
        #expect(claim.absolute == [9090])
        #expect(claim.named["cms"] == 4001)
        #expect(claim.named["metrics"] == 9090)
        #expect(claim.injections["CMS_PORT"] == 4001)
        #expect(claim.injections["METRICS_PORT"] == 9090)
        #expect(claim.allPorts == [4000, 4001, 9090])
    }

    @Test func spanAndNamedOffsetOverlapIsError() {
        let spec = ServerSpec(
            command: ["serve"],
            name: "web",
            port: 3000,
            ports: ["cms": SecondaryPort(offset: 1)],
            portSpan: 4)
        let resolved = PortClaim.resolve(spec: spec, effectivePort: 3000)
        #expect(resolved.claim == nil)
        #expect(resolved.error?.contains("overlaps portSpan") == true)
        #expect(PortClaim.configErrors(spec: spec).isEmpty == false)
    }

    @Test func materializerInjectsNamedEnvs() {
        let spec = ServerSpec(
            command: ["serve"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            portEnv: "PUBLIC_PORT",
            ports: ["cms": SecondaryPort(env: "CMS_PORT", offset: 1)],
            url: "http://app.localhost:3000/")
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 4100)
        #expect(next.env?["PUBLIC_PORT"] == "4100")
        #expect(next.env?["CMS_PORT"] == "4101")
        #expect(next.url == "http://app.localhost:4100/")
    }
}
