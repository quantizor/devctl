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
        iso8601Fractional.format(date)
    }

    public static func parseISO8601(_ string: String) -> Date? {
        (try? iso8601Fractional.parse(string)) ?? (try? iso8601Plain.parse(string))
    }

    /** FormatStyle values are Sendable structs, unlike ISO8601DateFormatter. */
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
    case serverRegister = "server.register"
    case serverStart = "server.start"
    case serverStatus = "server.status"
    case serverStop = "server.stop"
    case serverUnregister = "server.unregister"
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

public struct ServerResult: Codable, Equatable, Sendable {
    public var server: ServerStatus

    public init(server: ServerStatus) {
        self.server = server
    }
}

public struct ServerListResult: Codable, Equatable, Sendable {
    public var servers: [ServerStatus]

    public init(servers: [ServerStatus]) {
        self.servers = servers
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
