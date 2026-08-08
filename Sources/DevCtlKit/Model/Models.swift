import Foundation

/** Protocol and daemon version constants shared by all three products. */
public enum DevCtlVersion {
    /** Wire protocol major version; clients abort on mismatch with `version-mismatch`. */
    public static let proto = 1
    public static let version = "1.3.0"
}

/** Lifecycle phase of a supervised server. `failed` means the spawn itself never
    succeeded (ENOENT, EACCES) and is distinct from `crashed` (ran, then died). */
public enum ServerPhase: String, Codable, Sendable {
    case crashed
    case failed
    case running
    case starting
    case stopped
    case stopping
    case unhealthy
}

/** Healthcheck configuration. Absent spec + declared port implies a TCP probe;
    absent entirely means healthy = alive past a stabilization window. */
public struct HealthCheckSpec: Codable, Equatable, Sendable {
    public var healthyAfter: Int?
    public var intervalMs: Int?
    public var port: Int?
    public var timeoutMs: Int?
    public var type: HealthCheckType
    public var unhealthyAfter: Int?
    public var url: String?

    public init(
        healthyAfter: Int? = nil,
        intervalMs: Int? = nil,
        port: Int? = nil,
        timeoutMs: Int? = nil,
        type: HealthCheckType,
        unhealthyAfter: Int? = nil,
        url: String? = nil
    ) {
        self.healthyAfter = healthyAfter
        self.intervalMs = intervalMs
        self.port = port
        self.timeoutMs = timeoutMs
        self.type = type
        self.unhealthyAfter = unhealthyAfter
        self.url = url
    }
}

public enum HealthCheckType: String, Codable, Sendable {
    case http
    case none
    case tcp
}

/** How a dependent waits on its dependency during group startup. */
public enum WaitTarget: String, Codable, Sendable {
    case healthy
    case started
}

/** What `devctl wait` blocks on. */
public enum WaitCondition: String, Codable, Sendable {
    case healthy
    case stopped
}

/** Why an ensure/wait returned without reaching its target. Absent = reached. */
public enum EnsureReason: String, Codable, Sendable {
    case crashed
    case failed
    case stopped
    case timeout
}

/** Result of ensure/wait: the status plus the reason it fell short, if it did. */
public struct EnsureResult: Codable, Equatable, Sendable {
    public var reason: EnsureReason?
    public var server: ServerStatus

    public init(reason: EnsureReason? = nil, server: ServerStatus) {
        self.reason = reason
        self.server = server
    }
}

/** A server declaration: the unit of devservers.json and ad-hoc registration. */
public struct ServerSpec: Codable, Equatable, Sendable {
    public var command: [String]
    /** Relative to the project root. */
    public var cwd: String?
    public var dependsOn: [String]?
    public var env: [String: String]?
    /** Named entry points for a multi-headed server (a host-routing proxy
        serving several surfaces on one port): display name -> URL. */
    public var heads: [String: String]?
    public var healthcheck: HealthCheckSpec?
    /** Resolved server host (committed, worktree-derived, or overlay). Kept on
        the spec so port materialization can rebuild urls without re-reading
        the project file. Optional so older ad-hoc registry entries keep parsing. */
    public var host: String?
    /** Absolute path to an icon image (resolved from the config's
        project-relative path); used for Spotlight thumbnails. */
    public var icon: String?
    /** Named mutable resources this server holds while running (a local
        database, a fixture directory). `devctl lock <resource> -- cmd` stops
        holders for the command's duration, and starts are refused while a live
        external holder owns the resource. */
    public var locks: [String]?
    public var name: String
    public var port: Int?
    /** Child env var that receives the effective port (default `PORT`). */
    public var portEnv: String?
    /** Named secondary listeners (relative offsets or absolute singletons). */
    public var ports: [String: SecondaryPort]?
    /** Claim `effectivePort ..< effectivePort+portSpan` without naming each
        secondary. Sugar for apps that derive children from the primary env. */
    public var portSpan: Int?
    /** Runs the command through `/bin/zsh -lc` for shells that need login env (nvm/mise). */
    public var shell: Bool?
    public var url: String?
    public var waitFor: WaitTarget?

    public init(
        command: [String],
        cwd: String? = nil,
        dependsOn: [String]? = nil,
        env: [String: String]? = nil,
        heads: [String: String]? = nil,
        healthcheck: HealthCheckSpec? = nil,
        host: String? = nil,
        icon: String? = nil,
        locks: [String]? = nil,
        name: String,
        port: Int? = nil,
        portEnv: String? = nil,
        ports: [String: SecondaryPort]? = nil,
        portSpan: Int? = nil,
        shell: Bool? = nil,
        url: String? = nil,
        waitFor: WaitTarget? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.dependsOn = dependsOn
        self.env = env
        self.heads = heads
        self.healthcheck = healthcheck
        self.host = host
        self.icon = icon
        self.locks = locks
        self.name = name
        self.port = port
        self.portEnv = portEnv
        self.ports = ports
        self.portSpan = portSpan
        self.shell = shell
        self.url = url
        self.waitFor = waitFor
    }
}

/** Exit forensics for a server that ran and then died. */
public struct LastExit: Codable, Equatable, Sendable {
    public var at: Date
    public var code: Int?
    public var signal: Int?

    public init(at: Date, code: Int? = nil, signal: Int? = nil) {
        self.at = at
        self.code = code
        self.signal = signal
    }
}

/** Forensics for a spawn that never produced a process. */
public struct SpawnError: Codable, Equatable, Sendable {
    public var errno: Int?
    public var message: String

    public init(errno: Int? = nil, message: String) {
        self.errno = errno
        self.message = message
    }
}

/** Counted, never quoted: what devctl observed on a server's error stream during
    the current process's life. Every field is devctl's own arithmetic over the
    log, which is what makes it safe to put in an agent's session context where a
    child's own bytes must never go. */
public struct ErrorSummary: Codable, Equatable, Sendable {
    public var count: Int
    public var firstAt: Date
    public var lastAt: Date

    public init(count: Int, firstAt: Date, lastAt: Date) {
        self.count = count
        self.firstAt = firstAt
        self.lastAt = lastAt
    }
}

/** The core status schema agents consume; documented in docs/cli-contract.md. */
public struct ServerStatus: Codable, Equatable, Sendable {
    public var declaredPort: Int?
    public var effectivePort: Int?
    public var errorSummary: ErrorSummary?
    public var heads: [String: String]?
    public var healthcheck: HealthCheckType
    public var icon: String?
    public var lastExit: LastExit?
    public var lastHealthAt: Date?
    /** Resources this server holds while running, from its `locks` declaration.
        The machine-readable half of the hint `stop` prints: getting exclusive
        access to one of these is what `devctl lock` is for, and stopping the
        server is the heavier way to the same place. */
    public var locks: [String]?
    public var logPath: String
    public var observedPort: Int?
    public var phase: ServerPhase
    public var pid: Int?
    public var portConflict: PortConflict?
    /** Resolved named secondary ports when the spec declares `ports`. */
    public var ports: [String: Int]?
    public var project: String
    public var recentLogTail: [String]?
    public var server: String
    public var spawnError: SpawnError?
    public var specStale: Bool?
    /** Short spool evidence persisted across ensure/rehydrate for `why`. */
    public var terminalEvidence: [String]?
    public var uptimeSec: Int?
    public var url: String?

    public init(
        declaredPort: Int? = nil,
        effectivePort: Int? = nil,
        errorSummary: ErrorSummary? = nil,
        heads: [String: String]? = nil,
        healthcheck: HealthCheckType = .none,
        icon: String? = nil,
        lastExit: LastExit? = nil,
        lastHealthAt: Date? = nil,
        locks: [String]? = nil,
        logPath: String,
        observedPort: Int? = nil,
        phase: ServerPhase,
        pid: Int? = nil,
        portConflict: PortConflict? = nil,
        ports: [String: Int]? = nil,
        project: String,
        recentLogTail: [String]? = nil,
        server: String,
        spawnError: SpawnError? = nil,
        specStale: Bool? = nil,
        terminalEvidence: [String]? = nil,
        uptimeSec: Int? = nil,
        url: String? = nil
    ) {
        self.declaredPort = declaredPort
        self.effectivePort = effectivePort
        self.errorSummary = errorSummary
        self.heads = heads
        self.healthcheck = healthcheck
        self.icon = icon
        self.lastExit = lastExit
        self.lastHealthAt = lastHealthAt
        self.locks = locks
        self.logPath = logPath
        self.observedPort = observedPort
        self.phase = phase
        self.pid = pid
        self.portConflict = portConflict
        self.ports = ports
        self.project = project
        self.recentLogTail = recentLogTail
        self.server = server
        self.spawnError = spawnError
        self.specStale = specStale
        self.terminalEvidence = terminalEvidence
        self.uptimeSec = uptimeSec
        self.url = url
    }
}

/** The unified event feed: lifecycle transitions, health changes, and marks as
    one queryable stream. */
public enum EventKind: String, Codable, Sendable {
    case crashed
    case failed
    case healthy
    case marked
    case registered
    case started
    case stopped
    case unhealthy
    case unregistered
}

public struct EventRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var detail: String?
    public var kind: EventKind
    public var project: String
    public var server: String

    public init(at: Date, detail: String? = nil, kind: EventKind, project: String, server: String) {
        self.at = at
        self.detail = detail
        self.kind = kind
        self.project = project
        self.server = server
    }
}

/** Whether the menu bar should banner an event. Expected daemon bounce markers
    (`daemon-restart`) are forensics for the feed, not user alerts. */
public enum CrashNotificationPolicy {
    public static func shouldNotify(kind: EventKind, detail: String?) -> Bool {
        guard kind == .crashed || kind == .failed else { return false }
        if let detail, detail.hasPrefix("daemon-restart") { return false }
        return true
    }
}

/** One step in a `devctl why` diagnosis chain. */
public struct WhyFinding: Codable, Equatable, Sendable {
    public var evidence: [String]
    public var phase: ServerPhase
    public var server: String
    public var summary: String

    public init(evidence: [String] = [], phase: ServerPhase, server: String, summary: String) {
        self.evidence = evidence
        self.phase = phase
        self.server = server
        self.summary = summary
    }
}

public struct WhyResult: Codable, Equatable, Sendable {
    public var findings: [WhyFinding]
    /** The dependency-walk's best root-cause statement, when one stands out. */
    public var rootCause: String?

    public init(findings: [WhyFinding], rootCause: String? = nil) {
        self.findings = findings
        self.rootCause = rootCause
    }
}

/** Basic daemon identity returned by `daemon.info`. */
public struct DaemonInfo: Codable, Equatable, Sendable {
    public var dataDir: String
    public var daemonVersion: String
    public var logsDir: String
    public var pid: Int
    public var proto: Int
    public var searchPath: String?
    public var socketPath: String

    public init(
        dataDir: String,
        daemonVersion: String,
        logsDir: String,
        pid: Int,
        proto: Int,
        searchPath: String? = nil,
        socketPath: String
    ) {
        self.dataDir = dataDir
        self.daemonVersion = daemonVersion
        self.logsDir = logsDir
        self.pid = pid
        self.proto = proto
        self.searchPath = searchPath
        self.socketPath = socketPath
    }
}
