import Foundation

/** Central JSON coding: deterministic key order (golden tests depend on it) and
    ISO-8601 timestamps with milliseconds everywhere on the wire and in files. */
public enum JSONCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseISO8601(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "unparseable ISO-8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, e in
            var container = e.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func formatISO8601(_ date: Date) -> String {
        /** The fractional digits come from the ms integer directly:
            ISO8601FormatStyle TRUNCATES fractional seconds, so formatting
            Double(ms)/1000 (which can sit a hair below the true ms) would emit
            ms-1 and break round-trip equality. */
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let base = iso8601Plain.format(Date(timeIntervalSince1970: Double(ms / 1000)))
        return base.replacing("Z", with: String(format: ".%03dZ", ms % 1000))
    }

    /** The wire and file format carry millisecond precision, and Date equality
        across a store/parse round trip only holds if every path derives its
        Double from the same millisecond integer. canonicalMs is that fixpoint:
        format canonicalizes before emitting, parse canonicalizes after reading,
        so Date -> string -> Date is bit-identical. */
    public static func canonicalMs(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    public static func parseISO8601(_ string: String) -> Date? {
        let parsed = (try? iso8601Fractional.parse(string)) ?? (try? iso8601Plain.parse(string))
        return parsed.map(canonicalMs)
    }

    /** FormatStyle values are Sendable structs, unlike ISO8601DateFormatter.
        The fractional style exists for parsing only; see formatISO8601. */
    private static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Plain = Date.ISO8601FormatStyle()
}

/** Stable machine-readable failure codes agents branch on. Append-only. */
public enum WireErrorCode: String, Codable, Sendable {
    case configInvalid = "config-invalid"
    case daemonUnreachable = "daemon-unreachable"
    case internalError = "internal-error"
    case notFound = "not-found"
    case notTrusted = "not-trusted"
    case portHeld = "port-held"
    case resourceLocked = "resource-locked"
    case spawnFailed = "spawn-failed"
    case usage
    case versionMismatch = "version-mismatch"
}

/** Wire and CLI error shape; `hint` is the literal remediation command when one exists. */
public struct WireError: Codable, Error, Sendable {
    public var code: WireErrorCode
    public var hint: String?
    public var message: String

    public init(code: WireErrorCode, hint: String? = nil, message: String) {
        self.code = code
        self.hint = hint
        self.message = message
    }
}

/** A typed request frame. `params` is method-specific; the daemon sniffs
    `{id, method}` first, then re-decodes the full typed frame. */
public struct WireRequest<Params: Codable & Sendable>: Codable, Sendable {
    public var id: String
    public var method: String
    public var params: Params

    public init(id: String, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/** Minimal envelope used to sniff a frame before typed decoding. */
public struct WireRequestHead: Codable, Sendable {
    public var id: String
    public var method: String
}

public struct WireResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var error: WireError?
    public var id: String
    public var ok: Bool
    public var result: Result?

    public init(error: WireError? = nil, id: String, ok: Bool, result: Result? = nil) {
        self.error = error
        self.id = id
        self.ok = ok
        self.result = result
    }
}

public struct WireResponseHead: Codable, Sendable {
    public var error: WireError?
    public var id: String
    public var ok: Bool
}

/** Server-push frame (hello, and later log/status/event streams). */
public struct WireEvent<Params: Codable & Sendable>: Codable, Sendable {
    public var event: String
    public var params: Params
    public var sub: String?

    public init(event: String, params: Params, sub: String? = nil) {
        self.event = event
        self.params = params
        self.sub = sub
    }
}

public struct WireEventHead: Codable, Sendable {
    public var event: String
}

public struct HelloParams: Codable, Equatable, Sendable {
    public var daemonVersion: String
    public var proto: Int

    public init(daemonVersion: String, proto: Int) {
        self.daemonVersion = daemonVersion
        self.proto = proto
    }
}

/** Placeholder params/result for methods that need none. */
public struct WireEmpty: Codable, Equatable, Sendable {
    public init() {}
}

/** Method names; string-typed on the wire, enum-checked in code. */
public enum WireMethod: String, Sendable {
    case daemonInfo = "daemon.info"
    case daemonShutdown = "daemon.shutdown"
    case eventsQuery = "events.query"
    case groupDown = "group.down"
    case groupUp = "group.up"
    case lockAcquire = "lock.acquire"
    case lockRelease = "lock.release"
    case logsMark = "logs.mark"
    case logsQuery = "logs.query"
    case projectCheck = "project.check"
    case projectTrust = "project.trust"
    case projectWriteConfig = "project.writeConfig"
    case serverEnsure = "server.ensure"
    case serverRegister = "server.register"
    case serverStart = "server.start"
    case serverStatus = "server.status"
    case serverStop = "server.stop"
    case serverUnregister = "server.unregister"
    case serverWait = "server.wait"
    case serverWhy = "server.why"
}

// MARK: - Method payloads (phase 1 surface)

public struct ServerTargetParams: Codable, Equatable, Sendable {
    public var name: String
    public var project: String

    public init(name: String, project: String) {
        self.name = name
        self.project = project
    }
}

public struct ProjectParams: Codable, Equatable, Sendable {
    public var name: String?
    public var project: String

    public init(name: String? = nil, project: String) {
        self.name = name
        self.project = project
    }
}

public struct RegisterParams: Codable, Equatable, Sendable {
    public var project: String
    public var spec: ServerSpec

    public init(project: String, spec: ServerSpec) {
        self.project = project
        self.spec = spec
    }
}

public struct EnsureParams: Codable, Equatable, Sendable {
    public var name: String
    public var project: String
    public var timeoutSeconds: Double

    public init(name: String, project: String, timeoutSeconds: Double) {
        self.name = name
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct WaitParams: Codable, Equatable, Sendable {
    public var condition: WaitCondition
    public var name: String
    public var project: String
    public var timeoutSeconds: Double

    public init(condition: WaitCondition, name: String, project: String, timeoutSeconds: Double) {
        self.condition = condition
        self.name = name
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ServerResult: Codable, Equatable, Sendable {
    public var server: ServerStatus

    public init(server: ServerStatus) {
        self.server = server
    }
}

public struct ServerListResult: Codable, Equatable, Sendable {
    public var servers: [ServerStatus]
    /** Whether the scoped project's committed config is trusted; absent for
        machine-wide queries. The hook only advertises trusted projects. */
    public var trusted: Bool?

    public init(servers: [ServerStatus], trusted: Bool? = nil) {
        self.servers = servers
        self.trusted = trusted
    }
}

public struct GroupParams: Codable, Equatable, Sendable {
    public var only: [String]?
    public var project: String
    public var timeoutSeconds: Double

    public init(only: [String]? = nil, project: String, timeoutSeconds: Double = 60) {
        self.only = only
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct GroupResult: Codable, Equatable, Sendable {
    public var results: [EnsureResult]

    public init(results: [EnsureResult]) {
        self.results = results
    }
}

public struct LockParams: Codable, Equatable, Sendable {
    /** The lock auto-releases when this pid dies (a crashed harness never
        wedges the resource). */
    public var holderPid: Int
    public var project: String
    public var resource: String

    public init(holderPid: Int, project: String, resource: String) {
        self.holderPid = holderPid
        self.project = project
        self.resource = resource
    }
}

public struct LockHolder: Codable, Equatable, Sendable {
    public var pid: Int
    public var since: Date

    public init(pid: Int, since: Date) {
        self.pid = pid
        self.since = since
    }
}

public struct ProjectOnlyParams: Codable, Equatable, Sendable {
    public var project: String

    public init(project: String) {
        self.project = project
    }
}

public struct WriteConfigParams: Codable, Equatable, Sendable {
    /** hash8 of the bytes the editor loaded; the daemon rejects on mismatch so
        an IDE's concurrent save is never silently clobbered. Empty = file must
        not exist yet. */
    public var baselineHash: String
    public var content: String
    public var project: String

    public init(baselineHash: String, content: String, project: String) {
        self.baselineHash = baselineHash
        self.content = content
        self.project = project
    }
}

public struct CheckResult: Codable, Equatable, Sendable {
    public var errors: [String]
    public var host: String?
    public var servers: [String]
    public var warnings: [String]

    public init(errors: [String] = [], host: String? = nil, servers: [String] = [], warnings: [String] = []) {
        self.errors = errors
        self.host = host
        self.servers = servers
        self.warnings = warnings
    }
}

public struct LogsQueryParams: Codable, Equatable, Sendable {
    public var grep: String?
    public var name: String
    public var project: String
    public var since: Date?
    public var sinceMark: String?
    public var streams: [LogStream]?
    public var tail: Int?

    public init(
        grep: String? = nil,
        name: String,
        project: String,
        since: Date? = nil,
        sinceMark: String? = nil,
        streams: [LogStream]? = nil,
        tail: Int? = nil
    ) {
        self.grep = grep
        self.name = name
        self.project = project
        self.since = since
        self.sinceMark = sinceMark
        self.streams = streams
        self.tail = tail
    }
}

public struct LogsQueryResult: Codable, Equatable, Sendable {
    public var lines: [LogRecord]

    public init(lines: [LogRecord]) {
        self.lines = lines
    }
}

public struct MarkParams: Codable, Equatable, Sendable {
    /** Mark every server in the project instead of one by name. */
    public var all: Bool?
    public var label: String?
    public var name: String?
    public var project: String
    public var text: String

    public init(all: Bool? = nil, label: String? = nil, name: String? = nil, project: String, text: String) {
        self.all = all
        self.label = label
        self.name = name
        self.project = project
        self.text = text
    }
}

public struct MarkResult: Codable, Equatable, Sendable {
    public var marks: [PlacedMark]

    public init(marks: [PlacedMark]) {
        self.marks = marks
    }
}

public struct PlacedMark: Codable, Equatable, Sendable {
    public var at: Date
    public var id: String
    public var server: String

    public init(at: Date, id: String, server: String) {
        self.at = at
        self.id = id
        self.server = server
    }
}

public struct EventsQueryParams: Codable, Equatable, Sendable {
    public var project: String?
    public var since: Date?
    public var sinceMark: String?
    public var tail: Int?

    public init(project: String? = nil, since: Date? = nil, sinceMark: String? = nil, tail: Int? = nil) {
        self.project = project
        self.since = since
        self.sinceMark = sinceMark
        self.tail = tail
    }
}

public struct EventsQueryResult: Codable, Equatable, Sendable {
    public var events: [EventRecord]

    public init(events: [EventRecord]) {
        self.events = events
    }
}

// MARK: - NDJSON framing

/** Incremental NDJSON line assembler: feed raw bytes, get complete frames.
    JSONEncoder never emits interior newlines (no prettyPrinted), so framing on
    0x0A is safe. */
public struct NDJSONBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    /** Appends bytes and returns any newly completed lines (without the newline). */
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

public enum NDJSON {
    /** Encodes one frame with its trailing newline. */
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONCoding.encoder().encode(value)
        data.append(0x0A)
        return data
    }
}
