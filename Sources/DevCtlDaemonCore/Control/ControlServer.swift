import DevCtlKit
import Foundation
@preconcurrency import Network

/** Routes decoded requests to the registry and supervisor pool. One instance per
    daemon; connection handling fans out but every method lands here. */
public actor Router {
    private let launcher: any ProcessLauncher
    private let paths: DevCtlPaths
    private let registry: Registry
    private var supervisors: [String: ServerSupervisor] = [:]

    public init(launcher: any ProcessLauncher, paths: DevCtlPaths, registry: Registry) {
        self.launcher = launcher
        self.paths = paths
        self.registry = registry
    }

    /** Decodes the typed request for `method` and returns the encoded response
        frame. Any thrown WireError becomes the error envelope; anything else maps
        to internal-error so a client never sees a bare hang. */
    public func handle(line: Data) async -> Data {
        let decoder = JSONCoding.decoder()
        guard let head = try? decoder.decode(WireRequestHead.self, from: line) else {
            return (try? NDJSON.encodeLine(
                WireResponse<WireEmpty>(
                    error: WireError(code: .usage, message: "unparseable request frame"),
                    id: "?", ok: false))) ?? Data("{\"id\":\"?\",\"ok\":false}\n".utf8)
        }
        do {
            guard let method = WireMethod(rawValue: head.method) else {
                throw WireError(code: .usage, message: "unknown method \(head.method)")
            }
            switch method {
            case .daemonInfo:
                return try respond(id: head.id, result: daemonInfo())
            case .daemonShutdown:
                let frame = try respond(id: head.id, result: WireEmpty())
                Task { try? await Task.sleep(for: .milliseconds(50)); exitDaemon() }
                return frame
            case .serverRegister:
                let request = try decoder.decode(WireRequest<RegisterParams>.self, from: line)
                try await registry.register(project: request.params.project, spec: request.params.spec)
                let supervisor = await supervisor(project: request.params.project, spec: request.params.spec)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.status()))
            case .serverStart:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let supervisor = try await resolvedSupervisor(request.params)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.start()))
            case .serverStatus:
                let request = try decoder.decode(WireRequest<ProjectParams>.self, from: line)
                return try respond(id: head.id, result: await statusList(request.params))
            case .serverStop:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let supervisor = try await resolvedSupervisor(request.params)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.stop()))
            case .serverUnregister:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                try await registry.unregister(project: request.params.project, name: request.params.name)
                supervisors[serverID(project: request.params.project, name: request.params.name)] = nil
                return try respond(id: head.id, result: WireEmpty())
            }
        } catch let error as WireError {
            return (try? NDJSON.encodeLine(WireResponse<WireEmpty>(error: error, id: head.id, ok: false)))
                ?? Data()
        } catch {
            let wrapped = WireError(code: .internalError, message: String(describing: error))
            return (try? NDJSON.encodeLine(WireResponse<WireEmpty>(error: wrapped, id: head.id, ok: false)))
                ?? Data()
        }
    }

    /** Drain-stops every running supervisor; used by graceful daemon shutdown. */
    public func drainAll() async {
        for supervisor in supervisors.values {
            _ = await supervisor.stop()
        }
    }

    private func daemonInfo() -> DaemonInfo {
        DaemonInfo(
            dataDir: paths.dataDir.path,
            daemonVersion: DevCtlVersion.version,
            logsDir: paths.logsDir.path,
            pid: Int(getpid()),
            proto: DevCtlVersion.proto,
            searchPath: ProcessInfo.processInfo.environment["PATH"],
            socketPath: paths.socketPath
        )
    }

    private func exitDaemon() {
        exit(0)
    }

    private func resolvedSupervisor(_ params: ServerTargetParams) async throws -> ServerSupervisor {
        guard let spec = await registry.spec(project: params.project, name: params.name) else {
            throw WireError(
                code: .notFound,
                hint: "run: devctl status --json",
                message: "no server named '\(params.name)' is registered for \(params.project)"
            )
        }
        return await supervisor(project: params.project, spec: spec)
    }

    private func statusList(_ params: ProjectParams) async -> ServerListResult {
        var statuses: [ServerStatus] = []
        for spec in await registry.specs(project: params.project) {
            if let name = params.name, name != spec.name { continue }
            let supervisor = await supervisor(project: params.project, spec: spec)
            statuses.append(await supervisor.status())
        }
        return ServerListResult(servers: statuses)
    }

    private func supervisor(project: String, spec: ServerSpec) async -> ServerSupervisor {
        let id = serverID(project: project, name: spec.name)
        if let existing = supervisors[id] {
            await existing.updateSpec(spec)
            return existing
        }
        let created = ServerSupervisor(
            launcher: launcher, paths: paths, projectPath: project, registry: registry, spec: spec)
        supervisors[id] = created
        return created
    }

    private func respond<R: Codable & Sendable>(id: String, result: R) throws -> Data {
        try NDJSON.encodeLine(WireResponse(id: id, ok: true, result: result))
    }
}

/** NWListener over the unix socket. Each connection gets a hello frame, then an
    NDJSON request loop; each request runs in its own Task so a slow operation
    never blocks the connection. */
public final class ControlServer: Sendable {
    private let listener: NWListener
    private let router: Router

    public init(router: Router, socketPath: String) throws {
        self.router = router
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: socketDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        /** The flock in daemon main guarantees we are the only live daemon, so a
            leftover socket file is always stale and safe to remove. */
        unlink(socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
        listener.newConnectionHandler = { [router] connection in
            Self.serve(connection: connection, router: router)
        }
        chmod(socketPath, 0o600)
    }

    public func start() {
        listener.start(queue: DispatchQueue(label: "devctl.control"))
    }

    private static func serve(connection: NWConnection, router: Router) {
        let queue = DispatchQueue(label: "devctl.connection")
        connection.start(queue: queue)
        let hello = try? NDJSON.encodeLine(
            WireEvent(
                event: "hello",
                params: HelloParams(daemonVersion: DevCtlVersion.version, proto: DevCtlVersion.proto)))
        if let hello {
            connection.send(content: hello, completion: .contentProcessed { _ in })
        }
        receiveLoop(connection: connection, router: router, buffer: NDJSONBuffer())
    }

    private static func receiveLoop(connection: NWConnection, router: Router, buffer: NDJSONBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            /** Receive callbacks are serial per connection, so the buffer moves
                through the recursion by value rather than shared mutation. */
            var advanced = buffer
            if let data, !data.isEmpty {
                for line in advanced.feed(data) {
                    Task {
                        let response = await router.handle(line: line)
                        connection.send(content: response, completion: .contentProcessed { _ in })
                    }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receiveLoop(connection: connection, router: router, buffer: advanced)
        }
    }
}
