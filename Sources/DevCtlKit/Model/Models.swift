import Foundation

/** Protocol and daemon version constants shared by all three products. */
public enum DevCtlVersion {
    /** Wire protocol major version; clients abort on mismatch with `version-mismatch`. */
    public static let proto = 1
    public static let version = "0.1.0"
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

/** A server declaration: the unit of devservers.json and ad-hoc registration. */
public struct ServerSpec: Codable, Equatable, Sendable {
    public var command: [String]
    /** Relative to the project root. */
    public var cwd: String?
    public var dependsOn: [String]?
    public var env: [String: String]?
    public var healthcheck: HealthCheckSpec?
    public var name: String
    public var port: Int?
    /** Runs the command through `/bin/zsh -lc` for shells that need login env (nvm/mise). */
    public var shell: Bool?
    public var url: String?
    public var waitFor: WaitTarget?

    public init(
        command: [String],
        cwd: String? = nil,
        dependsOn: [String]? = nil,
        env: [String: String]? = nil,
        healthcheck: HealthCheckSpec? = nil,
        name: String,
        port: Int? = nil,
        shell: Bool? = nil,
        url: String? = nil,
        waitFor: WaitTarget? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.dependsOn = dependsOn
        self.env = env
        self.healthcheck = healthcheck
        self.name = name
        self.port = port
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

/** The core status schema agents consume; documented in docs/cli-contract.md. */
public struct ServerStatus: Codable, Equatable, Sendable {
    public var declaredPort: Int?
    public var healthcheck: HealthCheckType
    public var lastExit: LastExit?
    public var lastHealthAt: Date?
    public var logPath: String
    public var observedPort: Int?
    public var phase: ServerPhase
    public var pid: Int?
    public var project: String
    public var recentLogTail: [String]?
    public var server: String
    public var spawnError: SpawnError?
    public var specStale: Bool?
    public var uptimeSec: Int?
    public var url: String?

    public init(
        declaredPort: Int? = nil,
        healthcheck: HealthCheckType = .none,
        lastExit: LastExit? = nil,
        lastHealthAt: Date? = nil,
        logPath: String,
        observedPort: Int? = nil,
        phase: ServerPhase,
        pid: Int? = nil,
        project: String,
        recentLogTail: [String]? = nil,
        server: String,
        spawnError: SpawnError? = nil,
        specStale: Bool? = nil,
        uptimeSec: Int? = nil,
        url: String? = nil
    ) {
        self.declaredPort = declaredPort
        self.healthcheck = healthcheck
        self.lastExit = lastExit
        self.lastHealthAt = lastHealthAt
        self.logPath = logPath
        self.observedPort = observedPort
        self.phase = phase
        self.pid = pid
        self.project = project
        self.recentLogTail = recentLogTail
        self.server = server
        self.spawnError = spawnError
        self.specStale = specStale
        self.uptimeSec = uptimeSec
        self.url = url
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
