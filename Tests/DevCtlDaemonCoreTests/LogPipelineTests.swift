import DevCtlKit
import Foundation
import Testing

@testable import DevCtlDaemonCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "devctl-pipe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct LogStoreTests {
    @Test func clampKeepsTimestampsMonotonic() async throws {
        let store = LogStore(currentURL: try tempDir().appending(path: "current.log"))
        let late = Date()
        let early = late.addingTimeInterval(-3600)
        let first = await store.append(stream: .out, text: "one", at: late)
        /** A clock step backwards must not write a regressing timestamp. */
        let second = await store.append(stream: .out, text: "two", at: early)
        #expect(second.at >= first.at)
    }

    @Test func rotationShiftsFamilyAndKeepsWriting() async throws {
        let current = try tempDir().appending(path: "current.log")
        let store = LogStore(currentURL: current, maxBytes: 1200)
        for index in 0..<40 {
            await store.append(stream: .out, text: "line \(index) padding padding padding")
        }
        let rotated = current.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        /** The whole family still reads back in order through the query engine. */
        let all = await store.query(LogQueryOptions(streams: [.out]))
        #expect(all.count == 40)
        #expect(all.first?.text.hasPrefix("line 0 ") == true)
        #expect(all.last?.text.hasPrefix("line 39 ") == true)
    }

    @Test func marksCarryIDAndResolve() async throws {
        let currentURL = try tempDir().appending(path: "current.log")
        let store = LogStore(currentURL: currentURL)
        /** An explicit earlier timestamp: a ms-granular since-bound necessarily
            includes same-millisecond neighbors, so "before" must not share the
            mark's millisecond for this assertion to be deterministic. */
        await store.append(stream: .out, text: "before", at: Date().addingTimeInterval(-1))
        let mark = await store.appendMark(label: "pid-1", text: "test begins")
        await store.append(stream: .out, text: "after")
        #expect(await store.resolveMark(mark.id) == mark.at)
        let since = await store.query(LogQueryOptions(since: mark.at, streams: [.out]))
        #expect(since.map(\.text) == ["after"])
    }
}

@Suite struct SpoolTailerTests {
    @Test func tailsIncrementallyAndSanitizes() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        FileManager.default.createFile(atPath: spool.path, contents: nil)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(intervalMs: 20, store: store, stream: .out, url: spool)
        await tailer.start()
        let handle = try FileHandle(forWritingTo: spool)
        try handle.write(contentsOf: Data("plain line\n10%\r99%\rdone\n\u{1B}[32mgreen\u{1B}[0m\n".utf8))
        /** Binary junk must not break the pipeline. */
        try handle.write(contentsOf: Data([0xFF, 0xFE, 0x80] + Array("tail\n".utf8)))
        try handle.close()
        try await Task.sleep(for: .milliseconds(200))
        await tailer.stop()
        let records = await store.query(LogQueryOptions(streams: [.out]))
        let texts = records.map(\.text)
        #expect(texts.contains("plain line"))
        #expect(texts.contains("done"))
        #expect(texts.contains("green"))
        #expect(texts.contains { $0.hasSuffix("tail") })
    }
}

@Suite struct EventStoreTests {
    @Test func postAndQueryWithFilters() async throws {
        let store = EventStore(url: try tempDir().appending(path: "events.log"))
        await store.post(kind: .started, project: "/a", server: "web", detail: "pid 1")
        await store.post(kind: .crashed, project: "/a", server: "web", detail: "code=1")
        await store.post(kind: .started, project: "/b", server: "api")
        let all = await store.query()
        #expect(all.count == 3)
        let projectA = await store.query(project: "/a")
        #expect(projectA.map(\.kind) == [.started, .crashed])
        let tail = await store.query(tail: 1)
        #expect(tail.first?.server == "api")
    }
}

@Suite struct WhyEngineTests {
    private func status(_ name: String, _ phase: ServerPhase, exit: Int? = nil) -> ServerStatus {
        ServerStatus(
            lastExit: exit.map { LastExit(at: Date(timeIntervalSince1970: 1_700_000_000), code: $0) },
            logPath: "/logs/\(name)/current.log",
            phase: phase,
            project: "/p",
            server: name
        )
    }

    @Test func dependencyWalkFindsDeepRootCause() {
        let statuses = [
            "web": status("web", .unhealthy),
            "api": status("api", .crashed, exit: 1),
        ]
        let specs = [
            "web": ServerSpec(command: ["w"], dependsOn: ["api"], name: "web"),
            "api": ServerSpec(command: ["a"], name: "api"),
        ]
        let result = WhyEngine.diagnose(
            target: "web", statuses: statuses, specs: specs,
            errTail: { name in name == "api" ? ["ECONNREFUSED db:5432"] : [] })
        #expect(result.rootCause?.hasPrefix("api: crashed (exit 1)") == true)
        #expect(result.findings.count == 2)
        #expect(result.findings.first?.server == "web")
        let apiFinding = result.findings.first { $0.server == "api" }
        #expect(apiFinding?.evidence.contains("err: ECONNREFUSED db:5432") == true)
    }

    @Test func healthyTargetHasNoRootCause() {
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": status("web", .running)],
            specs: ["web": ServerSpec(command: ["w"], name: "web")],
            errTail: { _ in [] })
        #expect(result.rootCause == nil)
        #expect(result.findings.first?.summary == "running and healthy")
    }

    @Test func portMismatchIsSurfaced() {
        var mismatched = status("web", .running)
        mismatched.declaredPort = 3000
        mismatched.observedPort = 3001
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": mismatched],
            specs: ["web": ServerSpec(command: ["w"], name: "web", port: 3000)],
            errTail: { _ in [] })
        #expect(result.findings.first?.summary.contains("listening on 3001") == true)
    }
}
