import Foundation
import Testing

@testable import DevCtlKit

@Suite struct WireCodecTests {
    @Test func requestRoundTrip() throws {
        let request = WireRequest(
            id: "c1", method: WireMethod.serverStart.rawValue,
            params: ServerTargetParams(name: "web", project: "/tmp/proj"))
        let line = try NDJSON.encodeLine(request)
        #expect(line.last == 0x0A)
        let decoded = try JSONCoding.decoder().decode(
            WireRequest<ServerTargetParams>.self, from: line.dropLast())
        #expect(decoded.id == "c1")
        #expect(decoded.params == request.params)
    }

    @Test func responseErrorEnvelope() throws {
        let response = WireResponse<WireEmpty>(
            error: WireError(code: .notFound, hint: "run: devctl status --json", message: "nope"),
            id: "c2", ok: false)
        let line = try NDJSON.encodeLine(response)
        let head = try JSONCoding.decoder().decode(WireResponseHead.self, from: line.dropLast())
        #expect(head.ok == false)
        #expect(head.error?.code == .notFound)
        #expect(head.error?.hint == "run: devctl status --json")
    }

    @Test func iso8601MillisecondRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_752_868_000.123)
        let text = JSONCoding.formatISO8601(date)
        #expect(text.hasSuffix("Z"))
        #expect(text.contains("."))
        let parsed = JSONCoding.parseISO8601(text)
        #expect(parsed != nil)
        #expect(abs(parsed!.timeIntervalSince(date)) < 0.001)
    }

    @Test func ndjsonBufferSplitsFrames() {
        var buffer = NDJSONBuffer()
        let first = buffer.feed(Data("{\"a\":1}\n{\"b\":".utf8))
        #expect(first.count == 1)
        let second = buffer.feed(Data("2}\n".utf8))
        #expect(second.count == 1)
        #expect(String(data: second[0], encoding: .utf8) == "{\"b\":2}")
    }

    @Test func statusSchemaGolden() throws {
        let status = ServerStatus(
            declaredPort: 3000,
            healthcheck: .none,
            lastExit: LastExit(at: Date(timeIntervalSince1970: 1_752_868_000), code: 1),
            logPath: "/logs/web/current.log",
            phase: .crashed,
            project: "/tmp/proj",
            server: "web"
        )
        let json = String(data: try JSONCoding.encoder().encode(status), encoding: .utf8)!
        /** Sorted keys make this deterministic; the golden string is the contract. */
        #expect(
            json
                == #"{"declaredPort":3000,"healthcheck":"none","lastExit":{"at":"2025-07-18T19:46:40.000Z","code":1},"logPath":"/logs/web/current.log","phase":"crashed","project":"/tmp/proj","server":"web"}"#
        )
    }
}

@Suite struct PathTests {
    @Test func sunPathLimit() {
        #expect(DevCtlPaths.fitsSunPath("/tmp/short.sock"))
        #expect(!DevCtlPaths.fitsSunPath(String(repeating: "x", count: 104)))
    }

    @Test func serverIDShape() {
        #expect(serverID(project: "/a/b", name: "web") == "/a/b::web")
    }

    @Test func hash8Stable() {
        #expect(DevCtlPaths.hash8("/Users/x/code/proj") == DevCtlPaths.hash8("/Users/x/code/proj"))
        #expect(DevCtlPaths.hash8("/a") != DevCtlPaths.hash8("/b"))
        #expect(DevCtlPaths.hash8("/a").count == 8)
    }

    @Test func atomicWriteAndDefensiveLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "devctl-test-\(UUID().uuidString)")
        let file = dir.appending(path: "state.json")
        struct Payload: Codable, Equatable {
            var value: Int
        }
        try AtomicFile.write(try JSONCoding.encoder().encode(Payload(value: 7)), to: file)
        #expect(AtomicFile.loadDefensively(Payload.self, from: file) == Payload(value: 7))
        /** Corruption quarantines instead of throwing, and the original is moved aside. */
        try Data("not json".utf8).write(to: file)
        #expect(AtomicFile.loadDefensively(Payload.self, from: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        #expect(quarantined.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    /** Two writers inside one process must both succeed: a pid-only temp name
        made them rename the same temp file out from under each other, which is
        how the app lost agent.path when launch registration and the recovery
        poll wrote it at the same moment. */
    @Test func concurrentWritesToOneFileAllSucceed() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "devctl-test-\(UUID().uuidString)")
        let file = dir.appending(path: "agent.path")
        let payloads = (0..<8).map { "payload-\($0)" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    try AtomicFile.write(Data(payload.utf8), to: file)
                }
            }
            try await group.waitForAll()
        }
        let written = try String(decoding: Data(contentsOf: file), as: UTF8.self)
        #expect(payloads.contains(written))
        /** No temp files survive a clean run. */
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".agent.path.tmp-") }
        #expect(leftovers.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}
