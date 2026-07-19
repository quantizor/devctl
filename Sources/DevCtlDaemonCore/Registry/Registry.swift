import DevCtlKit
import Foundation

/** Persisted registry: which projects and servers exist, and whether the project's
    committed config has been trusted. */
public struct RegistryFile: Codable, Sendable {
    public var projects: [String: RegisteredProject]

    public init(projects: [String: RegisteredProject] = [:]) {
        self.projects = projects
    }
}

public struct RegisteredProject: Codable, Sendable {
    public var servers: [String: ServerSpec]
    public var trusted: Bool

    public init(servers: [String: ServerSpec] = [:], trusted: Bool = false) {
        self.servers = servers
        self.trusted = trusted
    }
}

/** Persisted last-known runtime state per server; survives daemon restarts and
    powers crash forensics + recovery. */
public struct StateFile: Codable, Sendable {
    public var servers: [String: PersistedServerState]

    public init(servers: [String: PersistedServerState] = [:]) {
        self.servers = servers
    }
}

public struct PersistedServerState: Codable, Sendable {
    public var lastExit: LastExit?
    public var phase: ServerPhase
    public var pid: Int?
    public var spawnError: SpawnError?
    public var startedAt: Date?

    public init(
        lastExit: LastExit? = nil,
        phase: ServerPhase = .stopped,
        pid: Int? = nil,
        spawnError: SpawnError? = nil,
        startedAt: Date? = nil
    ) {
        self.lastExit = lastExit
        self.phase = phase
        self.pid = pid
        self.spawnError = spawnError
        self.startedAt = startedAt
    }
}

/** Owner of registry.json and state.json. Loads defensively (quarantine on parse
    failure), writes atomically (temp + fsync + rename). */
public actor Registry {
    private let paths: DevCtlPaths
    private var registry: RegistryFile
    private var state: StateFile

    public init(paths: DevCtlPaths) {
        self.paths = paths
        self.registry = AtomicFile.loadDefensively(RegistryFile.self, from: paths.registryFile) ?? RegistryFile()
        self.state = AtomicFile.loadDefensively(StateFile.self, from: paths.stateFile) ?? StateFile()
    }

    public func allProjects() -> [String] {
        registry.projects.keys.sorted()
    }

    public func project(_ path: String) -> RegisteredProject? {
        registry.projects[path]
    }

    public func register(project: String, spec: ServerSpec) throws {
        var entry = registry.projects[project] ?? RegisteredProject()
        entry.servers[spec.name] = spec
        registry.projects[project] = entry
        try persistRegistry()
    }

    public func spec(project: String, name: String) -> ServerSpec? {
        registry.projects[project]?.servers[name]
    }

    public func specs(project: String) -> [ServerSpec] {
        (registry.projects[project]?.servers ?? [:]).values.sorted { $0.name < $1.name }
    }

    public func isTrusted(project: String) -> Bool {
        registry.projects[project]?.trusted ?? false
    }

    public func setTrusted(project: String) throws {
        var entry = registry.projects[project] ?? RegisteredProject()
        entry.trusted = true
        registry.projects[project] = entry
        try persistRegistry()
    }

    public func unregister(project: String, name: String) throws {
        registry.projects[project]?.servers[name] = nil
        if let entry = registry.projects[project], entry.servers.isEmpty {
            registry.projects[project] = nil
        }
        try persistRegistry()
    }

    public func persistedState(serverID: String) -> PersistedServerState? {
        state.servers[serverID]
    }

    public func allPersistedState() -> [String: PersistedServerState] {
        state.servers
    }

    public func updateState(serverID: String, _ mutate: (inout PersistedServerState) -> Void) throws {
        var entry = state.servers[serverID] ?? PersistedServerState()
        mutate(&entry)
        state.servers[serverID] = entry
        try persistState()
    }

    private func persistRegistry() throws {
        try AtomicFile.write(JSONCoding.encoder().encode(registry), to: paths.registryFile)
    }

    private func persistState() throws {
        try AtomicFile.write(JSONCoding.encoder().encode(state), to: paths.stateFile)
    }
}
