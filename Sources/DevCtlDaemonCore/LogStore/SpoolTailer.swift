import DevCtlKit
import Foundation

/** Tails one raw spool file (the fd the child writes; survives daemon death)
    into the structured LogStore. Polling keeps it simple and restart-safe; the
    interval is far below human perception and costs one stat when idle. */
actor SpoolTailer {
    private let intervalMs: Int
    /** Partial-line cap: a line longer than this flushes in segments. */
    private let maxPartialBytes = 16 * 1024
    private var offset: UInt64 = 0
    private var partial = Data()
    private let store: LogStore
    private let stream: LogStream
    private var task: Task<Void, Never>?
    private let url: URL

    init(intervalMs: Int = 100, store: LogStore, stream: LogStream, url: URL) {
        self.intervalMs = intervalMs
        self.store = store
        self.stream = stream
        self.url = url
    }

    func start() {
        guard task == nil else { return }
        task = Task { [intervalMs] in
            while !Task.isCancelled {
                await self.drain()
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    /** Stops polling after a final drain so exit-time output is not lost. */
    func stop() async {
        task?.cancel()
        task = nil
        await drain()
        await flushPartial()
    }

    private func drain() async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        /** Truncation (a fresh start reuses the path) resets the cursor. */
        if size < offset { offset = 0; partial.removeAll() }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        /** Advanced by what was actually read, never by the size measured before
            the read. `readToEnd` reads to the end as it stands when it runs, so a
            child that appends between the two calls hands back more bytes than
            `size` accounted for, and recording `size` would leave the cursor
            behind the data already ingested and re-ingest that tail on the next
            drain: duplicate lines in the log and a doubled error tally. */
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let lineData = partial.subdata(in: partial.startIndex..<newline)
            partial.removeSubrange(partial.startIndex...newline)
            await ingest(lineData)
        }
        if partial.count > maxPartialBytes {
            let chunk = partial
            partial.removeAll()
            await ingest(chunk)
        }
    }

    private func flushPartial() async {
        guard !partial.isEmpty else { return }
        let chunk = partial
        partial.removeAll()
        await ingest(chunk)
    }

    private func ingest(_ lineData: Data) async {
        /** Lossy decode handles binary junk; the sanitizer strips NULs, ANSI/OSC
            escapes, and spinner rewrites. */
        let text = LogSanitizer.sanitize(String(decoding: lineData, as: UTF8.self))
        guard !text.isEmpty else { return }
        await store.append(stream: stream, text: text)
    }
}
