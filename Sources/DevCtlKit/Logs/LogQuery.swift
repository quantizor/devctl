import Foundation

/** Query parameters for reading structured logs. `sinceMark` resolves to the
    timestamp of the mark whose payload begins with that id. */
public struct LogQueryOptions: Sendable {
    /** Swift Regex pattern (compiled once per run; Regex itself is not Sendable). */
    public var grep: String?
    public var since: Date?
    public var streams: Set<LogStream>?
    public var tail: Int?

    public init(
        grep: String? = nil,
        since: Date? = nil,
        streams: Set<LogStream>? = nil,
        tail: Int? = nil
    ) {
        self.grep = grep
        self.since = since
        self.streams = streams
        self.tail = tail
    }
}

/** File-level query engine over a structured log family (current.log plus
    rotated .1-.5). Timestamps are per-file monotonic (the store clamps on
    append), which is what makes the binary search sound. */
public enum LogQuery {
    /** Oldest-first file list for a log family: highest rotation number first. */
    public static func familyFiles(current: URL, rotations: Int = 5) -> [URL] {
        var files: [URL] = []
        for index in stride(from: rotations, through: 1, by: -1) {
            let rotated = current.appendingPathExtension("\(index)")
            if FileManager.default.fileExists(atPath: rotated.path) {
                files.append(rotated)
            }
        }
        if FileManager.default.fileExists(atPath: current.path) {
            files.append(current)
        }
        return files
    }

    /** Why a caller-supplied grep pattern will not compile, or nil when it will.
        Callers validate before querying: a pattern the engine cannot compile must
        not silently degrade into "no filter", because returning every line reads
        exactly like a query that matched everything. */
    public static func grepRejection(_ pattern: String) -> String? {
        do {
            _ = try Regex(pattern)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /** Counts records on the given streams and brackets them in time, without
        building the array. The count and the two timestamps are devctl's own
        arithmetic over the log, safe to put in an agent's context where the lines
        themselves must never go. `since` bounds the window to one process's run
        (current.log is append-only across spawns), and drives the same file-skip
        and binary search `run` uses, so it does not scan a long history. */
    public static func summarize(current: URL, streams: Set<LogStream>, since: Date?) -> ErrorSummary? {
        var count = 0
        var first: Date?
        var last: Date?
        for record in run(current: current, options: LogQueryOptions(since: since, streams: streams)) {
            count += 1
            if first == nil { first = record.at }
            last = record.at
        }
        guard count > 0, let first, let last else { return nil }
        return ErrorSummary(count: count, firstAt: first, lastAt: last)
    }

    public static func run(current: URL, options: LogQueryOptions) -> [LogRecord] {
        /** A pattern that will not compile filters nothing out, so it would
            answer with the whole log. Fail closed and say so instead: callers
            screen user input with grepRejection first. */
        var grep: Regex<AnyRegexOutput>?
        if let pattern = options.grep {
            guard let compiled = try? Regex(pattern) else {
                DevCtlLog.daemon.error("log query grep pattern does not compile: \(pattern)")
                return []
            }
            grep = compiled
        }
        var records: [LogRecord] = []
        for file in familyFiles(current: current) {
            /** Whole-file skip: a file whose last line predates `since` cannot
                contribute. */
            if let since = options.since,
                let last = lastLineTimestamp(of: file), last < since {
                continue
            }
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var startIndex = text.startIndex
            if let since = options.since {
                startIndex = firstLineIndex(atOrAfter: since, in: text)
            }
            for line in text[startIndex...].split(separator: "\n", omittingEmptySubsequences: true) {
                guard let record = LogRecord.parse(line) else { continue }
                if let since = options.since, record.at < since { continue }
                if let streams = options.streams, !streams.contains(record.stream) { continue }
                if let grep, (try? grep.firstMatch(in: record.text)) == nil { continue }
                records.append(record)
            }
        }
        if let tail = options.tail, records.count > tail {
            records.removeFirst(records.count - tail)
        }
        return records
    }

    /** Timestamp of a mark record whose payload starts with `<id>\t`. */
    public static func markDate(current: URL, markID: String) -> Date? {
        let marks = run(current: current, options: LogQueryOptions(streams: [.mark]))
        return marks.first { $0.text.hasPrefix("\(markID)\t") || $0.text == markID }?.at
    }

    /** Binary search over byte-offset midpoints: seek, scan to the next line
        start, read that line's timestamp prefix. Returns the string index of the
        first line whose timestamp is at or after `since`. */
    static func firstLineIndex(atOrAfter since: Date, in text: String) -> String.Index {
        let utf8 = text.utf8
        var low = 0
        var high = utf8.count
        while low < high {
            let mid = (low + high) / 2
            let lineStart = lineStartOffset(atOrBefore: mid, utf8: utf8)
            guard let stamp = timestamp(atOffset: lineStart, in: text) else {
                /** Unparseable midpoint line: fall back to linear from here. */
                high = lineStart
                if high <= low { break }
                continue
            }
            if stamp < since {
                let next = nextLineOffset(after: lineStart, utf8: utf8)
                if next == lineStart { break }
                low = next
            } else {
                high = lineStart
            }
        }
        let offset = lineStartOffset(atOrBefore: min(low, utf8.count), utf8: utf8)
        return text.utf8.index(text.utf8.startIndex, offsetBy: offset)
    }

    public static func lastLineTimestamp(of url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let window: UInt64 = 64 * 1024
        let offset = size > window ? size - window : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let stamp = LogRecord.timestampPrefix(of: line) { return stamp }
        }
        return nil
    }

    private static func lineStartOffset(atOrBefore offset: Int, utf8: String.UTF8View) -> Int {
        guard offset > 0 else { return 0 }
        var index = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
        while index > utf8.startIndex {
            let previous = utf8.index(before: index)
            if utf8[previous] == 0x0A {
                return utf8.distance(from: utf8.startIndex, to: index)
            }
            index = previous
        }
        return 0
    }

    private static func nextLineOffset(after offset: Int, utf8: String.UTF8View) -> Int {
        var index = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
        while index < utf8.endIndex {
            let current = utf8[index]
            index = utf8.index(after: index)
            if current == 0x0A {
                return utf8.distance(from: utf8.startIndex, to: index)
            }
        }
        return utf8.distance(from: utf8.startIndex, to: utf8.endIndex)
    }

    private static func timestamp(atOffset offset: Int, in text: String) -> Date? {
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        guard let lineEnd = text[start...].firstIndex(of: "\n") else {
            return LogRecord.timestampPrefix(of: text[start...])
        }
        return LogRecord.timestampPrefix(of: text[start..<lineEnd])
    }
}
