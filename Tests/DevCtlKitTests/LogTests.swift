import Foundation
import Testing

@testable import DevCtlKit

@Suite struct LogFormatTests {
    @Test func recordRoundTrip() {
        let record = LogRecord(
            at: Date(timeIntervalSince1970: 1_752_868_000.5), stream: .out, text: "hello\tworld")
        let line = record.formatted()
        let parsed = LogRecord.parse(line[...])
        /** Payload tabs survive: parsers split on the first two tabs only. */
        #expect(parsed == record)
    }

    @Test func unparseableLinesReturnNil() {
        #expect(LogRecord.parse("no tabs here") == nil)
        #expect(LogRecord.parse("2026-01-01T00:00:00.000Z\tbogus\ttext") == nil)
        #expect(LogRecord.parse("not-a-date\tout\ttext") == nil)
    }

    @Test func sanitizerStripsSpinnersAnsiAndNul() {
        #expect(LogSanitizer.sanitize("10%\r50%\r100% done") == "100% done")
        #expect(LogSanitizer.sanitize("\u{1B}[31mred\u{1B}[0m plain") == "red plain")
        #expect(LogSanitizer.sanitize("\u{1B}]0;title\u{7}after") == "after")
        #expect(LogSanitizer.sanitize("nul\u{0}led") == "nulled")
    }
}

@Suite struct LogQueryTests {
    private func writeFamily(_ linesPerFile: [[LogRecord]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "devctl-logq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appending(path: "current.log")
        /** linesPerFile oldest-first: earlier arrays land in higher rotations. */
        for (index, records) in linesPerFile.enumerated() {
            let isCurrent = index == linesPerFile.count - 1
            let url = isCurrent
                ? current
                : current.appendingPathExtension("\(linesPerFile.count - 1 - index)")
            let text = records.map { $0.formatted() }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: url)
        }
        return current
    }

    private func record(_ offset: TimeInterval, _ stream: LogStream, _ text: String) -> LogRecord {
        LogRecord(at: Date(timeIntervalSince1970: 1_700_000_000 + offset), stream: stream, text: text)
    }

    @Test func sinceSkipsWholeFilesAndBinarySearches() throws {
        let old = (0..<100).map { record(Double($0), .out, "old \($0)") }
        let recent = (100..<200).map { record(Double($0), .out, "recent \($0)") }
        let current = try writeFamily([old, recent])
        let results = LogQuery.run(
            current: current,
            options: LogQueryOptions(since: Date(timeIntervalSince1970: 1_700_000_150)))
        #expect(results.count == 50)
        #expect(results.first?.text == "recent 150")
        #expect(results.last?.text == "recent 199")
    }

    @Test func grepStreamsAndTailCompose() throws {
        let lines = [
            record(1, .out, "listening on 3000"),
            record(2, .err, "warning: deprecated"),
            record(3, .err, "error: boom"),
            record(4, .out, "ok"),
            record(5, .err, "error: bang"),
        ]
        let current = try writeFamily([lines])
        let errors = LogQuery.run(
            current: current,
            options: LogQueryOptions(grep: "error", streams: [.err], tail: 1))
        #expect(errors.map(\.text) == ["error: bang"])
    }

    @Test func markResolution() throws {
        let lines = [
            record(1, .out, "before"),
            record(2, .mark, "m1700-1\tpid-99\tcheckout test begins"),
            record(3, .out, "after"),
        ]
        let current = try writeFamily([lines])
        let markDate = LogQuery.markDate(current: current, markID: "m1700-1")
        #expect(markDate == Date(timeIntervalSince1970: 1_700_000_002))
        #expect(LogQuery.markDate(current: current, markID: "m-nope") == nil)
    }
}
