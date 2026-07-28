import Foundation

/** A named secondary listener relative to the effective primary, or an absolute
    machine-singleton port. Exactly one of `offset` or `port` must be set. */
public struct SecondaryPort: Codable, Equatable, Sendable {
    public var env: String?
    public var offset: Int?
    public var port: Int?

    public init(env: String? = nil, offset: Int? = nil, port: Int? = nil) {
        self.env = env
        self.offset = offset
        self.port = port
    }

    /** Nil when the entry is well-formed; otherwise a config-check message. */
    public func validationError(name: String) -> String? {
        switch (offset, port) {
        case (nil, nil):
            return "ports.\(name): set offset or port"
        case (.some, .some):
            return "ports.\(name): set offset or port, not both"
        case (.some(let value), nil) where value < 0:
            return "ports.\(name): offset must be >= 0"
        case (nil, .some(let value)) where value < 1 || value > 65_535:
            return "ports.\(name): port must be 1...65535"
        default:
            return nil
        }
    }
}

/** Every port a spawn claims: primary, optional consecutive span sugar, and
    named secondaries. Pure; allocate / settle / materialize all use this set. */
public struct PortClaim: Equatable, Sendable {
    /** Fixed ports that never shift with sibling rebind. */
    public var absolute: [Int]
    /** Env key → resolved number for child injection (primary + named with env). */
    public var injections: [String: Int]
    /** Named secondary → resolved number (for status / agents). */
    public var named: [String: Int]
    public var primary: Int?
    /** Primary plus every relative member (span sugar and named offsets). */
    public var relative: [Int]

    public init(
        absolute: [Int] = [],
        injections: [String: Int] = [:],
        named: [String: Int] = [:],
        primary: Int? = nil,
        relative: [Int] = []
    ) {
        self.absolute = absolute
        self.injections = injections
        self.named = named
        self.primary = primary
        self.relative = relative
    }

    /** Unique sorted ports that must be free for this claim. */
    public var allPorts: [Int] {
        Array(Set(relative + absolute)).sorted()
    }

    /** Offsets from primary that must stay free when searching for a rebound
        base (excludes primary itself as offset 0). Absolute ports are not
        included: they never move. */
    public var relativeOffsets: [Int] {
        guard let primary else { return [] }
        return relative.compactMap { port in
            let offset = port - primary
            return offset >= 0 ? offset : nil
        }.sorted()
    }

    /** Build a claim from a materialized-ready spec and its effective primary.
        `error` is a config-shaped message when span and named offsets collide. */
    public static func resolve(spec: ServerSpec, effectivePort: Int?) -> (
        claim: PortClaim?, error: String?
    ) {
        var relative: Set<Int> = []
        var absolute: Set<Int> = []
        var named: [String: Int] = [:]
        var injections: [String: Int] = [:]
        if let primary = effectivePort {
            relative.insert(primary)
            let envKey = spec.portEnv ?? "PORT"
            injections[envKey] = primary
        }
        if let span = spec.portSpan {
            guard span >= 1 else {
                return (nil, "portSpan must be >= 1")
            }
            guard let primary = effectivePort else {
                return (nil, "portSpan requires a primary port")
            }
            for offset in 0..<span {
                relative.insert(primary + offset)
            }
        }
        var spanOffsets: Set<Int> = []
        if let span = spec.portSpan, span > 1 {
            spanOffsets = Set(1..<span)
        }
        for (name, secondary) in (spec.ports ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let error = secondary.validationError(name: name) {
                return (nil, error)
            }
            if let offset = secondary.offset {
                if spanOffsets.contains(offset) {
                    return (
                        nil,
                        "ports.\(name) offset \(offset) overlaps portSpan; pick one declaration")
                }
                guard let primary = effectivePort else {
                    return (nil, "ports.\(name): offset requires a primary port")
                }
                let resolved = primary + offset
                relative.insert(resolved)
                named[name] = resolved
                if let env = secondary.env {
                    injections[env] = resolved
                }
            } else if let port = secondary.port {
                absolute.insert(port)
                named[name] = port
                if let env = secondary.env {
                    injections[env] = port
                }
            }
        }
        return (
            PortClaim(
                absolute: absolute.sorted(),
                injections: injections,
                named: named,
                primary: effectivePort,
                relative: relative.sorted()),
            nil)
    }

    /** Config-time checks that do not need an effective (rebound) primary. */
    public static func configErrors(spec: ServerSpec) -> [String] {
        var errors: [String] = []
        if let span = spec.portSpan, span < 1 {
            errors.append("server '\(spec.name)': portSpan must be >= 1")
        }
        var spanOffsets: Set<Int> = []
        if let span = spec.portSpan, span > 1 {
            spanOffsets = Set(1..<span)
        }
        for (name, secondary) in spec.ports ?? [:] {
            if let error = secondary.validationError(name: name) {
                errors.append("server '\(spec.name)': \(error)")
            }
            if let offset = secondary.offset, spanOffsets.contains(offset) {
                errors.append(
                    "server '\(spec.name)': ports.\(name) offset \(offset) overlaps portSpan")
            }
        }
        return errors
    }
}
