import DevCtlKit
import Foundation
@preconcurrency import Network

/** Routes decoded requests to the registry and supervisor pool. One instance per
    daemon; connection handling fans out but every method lands here. */
public actor Router {
    private let events: EventStore
    private let launcher: any ProcessLauncher
    private let paths: DevCtlPaths
    private let registry: Registry
    private var supervisors: [String: ServerSupervisor] = [:]
    /** devservers.json views cached by mtime; a save invalidates naturally. */
    private var configCache: [String: (mtime: Date, view: ProjectConfigView)] = [:]
    /** Held resource locks keyed `project::resource`; stale holders (dead pids)
        evaporate on access, so a crashed harness never wedges a resource. */
    private var resourceLocks: [String: LockHolder] = [:]

    public init(launcher: any ProcessLauncher, paths: DevCtlPaths, registry: Registry) {
        self.events = EventStore(url: paths.eventsFile)
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
                Task { [weak self] in
                    guard let self else { return }
                    await self.drainAll()
                    /** Deliberate shutdown stays down: the intent marker keeps
                        auto-bootstrap from resurrecting the daemon, and exit 0
                        satisfies KeepAlive={SuccessfulExit:false}. */
                    try? Data().write(to: await self.paths.stoppedIntentFile)
                    await self.exitDaemon()
                }
                return frame
            case .serverRegister:
                let request = try decoder.decode(WireRequest<RegisterParams>.self, from: line)
                try await registry.register(project: request.params.project, spec: request.params.spec)
                let supervisor = await supervisor(project: request.params.project, spec: request.params.spec)
                await events.post(
                    kind: .registered, project: request.params.project, server: request.params.spec.name)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.status()))
            case .serverEnsure:
                let request = try decoder.decode(WireRequest<EnsureParams>.self, from: line)
                let target = ServerTargetParams(name: request.params.name, project: request.params.project)
                let merged = try await mergedSpecs(project: target.project)
                let supervisor = try await resolvedSupervisor(target)
                await recordTrustIfNeeded(project: target.project, name: target.name, fileNames: merged.fileNames)
                if let spec = merged.specs.first(where: { $0.name == target.name }) {
                    try lockGate(project: target.project, spec: spec)
                }
                try await portPreCheck(target: target, supervisor: supervisor)
                let result = await supervisor.ensure(timeoutSeconds: request.params.timeoutSeconds)
                return try respond(id: head.id, result: result)
            case .serverStart:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let merged = try await mergedSpecs(project: request.params.project)
                let supervisor = try await resolvedSupervisor(request.params)
                await recordTrustIfNeeded(
                    project: request.params.project, name: request.params.name, fileNames: merged.fileNames)
                if let spec = merged.specs.first(where: { $0.name == request.params.name }) {
                    try lockGate(project: request.params.project, spec: spec)
                }
                try await portPreCheck(target: request.params, supervisor: supervisor)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.start()))
            case .serverStatus:
                let request = try decoder.decode(WireRequest<ProjectParams>.self, from: line)
                return try respond(id: head.id, result: try await statusList(request.params))
            case .projectTrust:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                try await registry.setTrusted(project: request.params.project)
                return try respond(id: head.id, result: WireEmpty())
            case .projectCheck:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                let url = ProjectConfigLoader.configURL(project: request.params.project)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return try respond(
                        id: head.id,
                        result: CheckResult(errors: ["no devservers.json at \(url.path)"]))
                }
                do {
                    guard let view = try ProjectConfigLoader.load(project: request.params.project) else {
                        return try respond(
                            id: head.id, result: CheckResult(errors: ["cannot read \(url.path)"]))
                    }
                    return try respond(
                        id: head.id,
                        result: CheckResult(
                            errors: view.errors,
                            host: view.host,
                            servers: view.specs.map(\.name),
                            warnings: view.warnings))
                } catch let error as WireError {
                    return try respond(id: head.id, result: CheckResult(errors: [error.message]))
                }
            case .projectWriteConfig:
                let request = try decoder.decode(WireRequest<WriteConfigParams>.self, from: line)
                let url = ProjectConfigLoader.configURL(project: request.params.project)
                let currentHash = (try? Data(contentsOf: url)).map {
                    DevCtlPaths.hash8(String(decoding: $0, as: UTF8.self))
                } ?? ""
                guard currentHash == request.params.baselineHash else {
                    throw WireError(
                        code: .configInvalid,
                        hint: "reload the file and re-apply your edit",
                        message: "devservers.json changed on disk since it was loaded (an editor or another session saved it)")
                }
                let parsed: ProjectFileConfig
                do {
                    parsed = try JSONCoding.decoder().decode(
                        ProjectFileConfig.self, from: Data(request.params.content.utf8))
                } catch {
                    throw ProjectConfigLoader.configError(from: error, at: url)
                }
                let view = ProjectConfigLoader.validate(config: parsed, project: request.params.project)
                guard view.errors.isEmpty else {
                    throw WireError(
                        code: .configInvalid,
                        hint: "run: devctl config check",
                        message: view.errors.joined(separator: "; "))
                }
                try AtomicFile.write(Data(request.params.content.utf8), to: url)
                configCache[request.params.project] = nil
                return try respond(
                    id: head.id,
                    result: CheckResult(
                        host: view.host, servers: view.specs.map(\.name), warnings: view.warnings))
            case .groupUp:
                let request = try decoder.decode(WireRequest<GroupParams>.self, from: line)
                return try respond(id: head.id, result: try await groupUp(request.params))
            case .groupDown:
                let request = try decoder.decode(WireRequest<GroupParams>.self, from: line)
                return try respond(id: head.id, result: try await groupDown(request.params))
            case .serverStop:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let supervisor = try await resolvedSupervisor(request.params)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.stop()))
            case .serverWait:
                let request = try decoder.decode(WireRequest<WaitParams>.self, from: line)
                let target = ServerTargetParams(name: request.params.name, project: request.params.project)
                let supervisor = try await resolvedSupervisor(target)
                let reason = await supervisor.wait(
                    for: request.params.condition, timeoutSeconds: request.params.timeoutSeconds)
                return try respond(
                    id: head.id, result: EnsureResult(reason: reason, server: await supervisor.status()))
            case .lockAcquire:
                let request = try decoder.decode(WireRequest<LockParams>.self, from: line)
                let key = "\(request.params.project)::\(request.params.resource)"
                if let holder = liveLockHolder(key: key), holder.pid != request.params.holderPid {
                    throw WireError(
                        code: .resourceLocked,
                        hint: "wait for pid \(holder.pid) to finish, or verify it: ps -p \(holder.pid)",
                        message: "resource '\(request.params.resource)' is locked by pid \(holder.pid) since \(JSONCoding.formatISO8601(holder.since))")
                }
                resourceLocks[key] = LockHolder(pid: request.params.holderPid, since: Date())
                return try respond(id: head.id, result: WireEmpty())
            case .lockRelease:
                let request = try decoder.decode(WireRequest<LockParams>.self, from: line)
                let key = "\(request.params.project)::\(request.params.resource)"
                if resourceLocks[key]?.pid == request.params.holderPid {
                    resourceLocks[key] = nil
                }
                return try respond(id: head.id, result: WireEmpty())
            case .logsQuery:
                let request = try decoder.decode(WireRequest<LogsQueryParams>.self, from: line)
                let target = ServerTargetParams(name: request.params.name, project: request.params.project)
                let supervisor = try await resolvedSupervisor(target)
                var since = request.params.since
                if let markID = request.params.sinceMark {
                    guard let markDate = await supervisor.resolveMark(markID) else {
                        throw WireError(
                            code: .notFound,
                            hint: "run: devctl logs \(request.params.name) --stream mark",
                            message: "no mark with id '\(markID)' in \(request.params.name)'s log")
                    }
                    since = markDate
                }
                let options = LogQueryOptions(
                    grep: request.params.grep,
                    since: since,
                    streams: request.params.streams.map(Set.init),
                    tail: request.params.tail)
                let lines = await supervisor.logQuery(options)
                return try respond(id: head.id, result: LogsQueryResult(lines: lines))
            case .logsMark:
                let request = try decoder.decode(WireRequest<MarkParams>.self, from: line)
                let label = request.params.label ?? "cli"
                var marks: [PlacedMark] = []
                if request.params.all == true {
                    for spec in await registry.specs(project: request.params.project) {
                        let supervisor = await supervisor(project: request.params.project, spec: spec)
                        marks.append(await supervisor.placeMark(label: label, text: request.params.text))
                    }
                } else if let name = request.params.name {
                    let target = ServerTargetParams(name: name, project: request.params.project)
                    let supervisor = try await resolvedSupervisor(target)
                    marks.append(await supervisor.placeMark(label: label, text: request.params.text))
                } else {
                    throw WireError(code: .usage, message: "mark needs a server name or --all")
                }
                return try respond(id: head.id, result: MarkResult(marks: marks))
            case .eventsQuery:
                let request = try decoder.decode(WireRequest<EventsQueryParams>.self, from: line)
                var since = request.params.since
                if let markID = request.params.sinceMark, let project = request.params.project {
                    for spec in await registry.specs(project: project) {
                        let supervisor = await supervisor(project: project, spec: spec)
                        if let markDate = await supervisor.resolveMark(markID) {
                            since = markDate
                            break
                        }
                    }
                    if since == nil, request.params.since == nil {
                        throw WireError(
                            code: .notFound,
                            message: "no mark with id '\(markID)' in this project's logs")
                    }
                }
                let events = await events.query(
                    project: request.params.project, since: since, tail: request.params.tail)
                return try respond(id: head.id, result: EventsQueryResult(events: events))
            case .serverWhy:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                _ = try await resolvedSupervisor(request.params)
                var statuses: [String: ServerStatus] = [:]
                var specsByName: [String: ServerSpec] = [:]
                for spec in await registry.specs(project: request.params.project) {
                    let supervisor = await supervisor(project: request.params.project, spec: spec)
                    statuses[spec.name] = await supervisor.status()
                    specsByName[spec.name] = spec
                }
                let project = request.params.project
                let paths = self.paths
                let result = WhyEngine.diagnose(
                    target: request.params.name,
                    statuses: statuses,
                    specs: specsByName,
                    errTail: { server in
                        LogQuery.run(
                            current: paths.structuredLogFile(project: project, server: server),
                            options: LogQueryOptions(streams: [.err], tail: 5)
                        ).map(\.text)
                    })
                return try respond(id: head.id, result: result)
            case .serverUnregister:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                try await registry.unregister(project: request.params.project, name: request.params.name)
                supervisors[serverID(project: request.params.project, name: request.params.name)] = nil
                await events.post(
                    kind: .unregistered, project: request.params.project, server: request.params.name)
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

    /** Drain-stops every supervisor in parallel: a serial drain of N servers at
        up to 7s grace each would blow through launchd's ExitTimeOut. */
    public func drainAll() async {
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors.values {
                group.addTask { _ = await supervisor.stop() }
            }
        }
    }

    /** Startup recovery: reconcile persisted state with reality. A recorded pid
        that is gone becomes crashed(daemon-restart); a live orphan (its spool fd
        kept it healthy while the daemon was away) is group-killed and, if it was
        running, started fresh, since exit forensics are unknowable for
        non-children. Never adopted silently. */
    public func recoverAtStartup() async {
        for (id, persisted) in await registry.allPersistedState() {
            guard let separator = id.range(of: "::"), persisted.pid != nil || persisted.phase == .running || persisted.phase == .starting
            else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
            guard let spec = await registry.spec(project: project, name: name) else { continue }
            let wasRunning = persisted.phase == .running || persisted.phase == .starting
            if let pid = persisted.pid.map(pid_t.init), kill(pid, 0) == 0 {
                let descendants = ProcessTree.descendants(of: pid)
                ProcessTree.signalTree(rootPid: pid, descendants: descendants, signal: SIGTERM)
                try? await Task.sleep(for: .seconds(2))
                if kill(pid, 0) == 0 {
                    ProcessTree.signalTree(rootPid: pid, descendants: descendants, signal: SIGKILL)
                }
                await events.post(
                    kind: .crashed, project: project, server: name,
                    detail: "daemon-restart: orphan pid \(pid) bounced")
            } else if wasRunning {
                await events.post(
                    kind: .crashed, project: project, server: name, detail: "daemon-restart")
            }
            try? await registry.updateState(serverID: id) { entry in
                entry.lastExit = entry.lastExit ?? LastExit(at: Date())
                entry.phase = .crashed
                entry.pid = nil
            }
            if wasRunning {
                let supervisor = await supervisor(project: project, spec: spec)
                _ = await supervisor.start()
            }
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

    /** Fails a start-shaped request when the declared port is already held: by a
        managed server elsewhere (the two-worktrees case, named precisely) or by
        an unmanaged squatter (pid + command when lsof can see it). Runs only when
        the target itself is not already up, so a server never conflicts with its
        own listener. */
    private func portPreCheck(target: ServerTargetParams, supervisor: ServerSupervisor) async throws {
        let current = await supervisor.status()
        switch current.phase {
        case .running, .starting, .stopping, .unhealthy:
            return
        case .crashed, .failed, .stopped:
            break
        }
        guard let port = current.declaredPort else { return }
        let targetID = serverID(project: target.project, name: target.name)
        for (id, other) in supervisors where id != targetID {
            let status = await other.status()
            let active = status.phase == .running || status.phase == .starting || status.phase == .unhealthy
            if active, status.declaredPort == port || status.observedPort == port {
                throw WireError(
                    code: .portHeld,
                    hint: "run: devctl stop \(status.server) --project \(status.project)",
                    message: "port \(port) is held by managed server '\(status.server)' in \(status.project)"
                )
            }
        }
        if PortGuard.isListening(port: port) {
            if let squatter = PortGuard.listenerInfo(port: port) {
                throw WireError(
                    code: .portHeld,
                    hint: "run: kill \(squatter.pid)  (verify first: ps -p \(squatter.pid))",
                    message: "port \(port) is held by unmanaged pid \(squatter.pid) (\(squatter.command))"
                )
            }
            throw WireError(
                code: .portHeld,
                message: "port \(port) already has a listener that devctl does not manage"
            )
        }
    }

    /** The merged project view: committed devservers.json specs (source of
        truth for their names) plus ad-hoc registry entries. Throws
        config-invalid when the file exists but cannot be used. */
    private func mergedSpecs(project: String) async throws -> (specs: [ServerSpec], fileNames: Set<String>) {
        var specs: [String: ServerSpec] = [:]
        for spec in await registry.specs(project: project) {
            specs[spec.name] = spec
        }
        var fileNames: Set<String> = []
        if let view = try loadConfig(project: project) {
            guard view.errors.isEmpty else {
                throw WireError(
                    code: .configInvalid,
                    hint: "run: devctl config check",
                    message: "devservers.json is invalid: \(view.errors.joined(separator: "; "))")
            }
            for spec in view.specs {
                specs[spec.name] = spec
                fileNames.insert(spec.name)
            }
        }
        return (specs: specs.values.sorted { $0.name < $1.name }, fileNames: fileNames)
    }

    private func loadConfig(project: String) throws -> ProjectConfigView? {
        let url = ProjectConfigLoader.configURL(project: project)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtime = attributes[.modificationDate] as? Date
        else {
            configCache[project] = nil
            return nil
        }
        if let cached = configCache[project], cached.mtime == mtime {
            return cached.view
        }
        guard let view = try ProjectConfigLoader.load(project: project) else { return nil }
        configCache[project] = (mtime: mtime, view: view)
        return view
    }

    /** Acting on a committed config is what records trust: an explicit start or
        ensure IS the approval. The hook advertises only already-trusted projects. */
    private func recordTrustIfNeeded(project: String, name: String, fileNames: Set<String>) async {
        if fileNames.contains(name), await !registry.isTrusted(project: project) {
            try? await registry.setTrusted(project: project)
        }
    }

    private func liveLockHolder(key: String) -> LockHolder? {
        guard let holder = resourceLocks[key] else { return nil }
        guard kill(pid_t(holder.pid), 0) == 0 else {
            resourceLocks[key] = nil
            return nil
        }
        return holder
    }

    /** Refuses to start a server while an external holder owns one of its
        declared resources: restarting mid-harness-run is exactly the contention
        the lock exists to prevent. */
    private func lockGate(project: String, spec: ServerSpec) throws {
        for resource in spec.locks ?? [] {
            if let holder = liveLockHolder(key: "\(project)::\(resource)") {
                throw WireError(
                    code: .resourceLocked,
                    hint: "the holder releases it when done; check: ps -p \(holder.pid)",
                    message: "server '\(spec.name)' holds resource '\(resource)', locked by pid \(holder.pid) since \(JSONCoding.formatISO8601(holder.since))")
            }
        }
    }

    private func resolvedSupervisor(_ params: ServerTargetParams) async throws -> ServerSupervisor {
        let merged = try await mergedSpecs(project: params.project)
        guard let spec = merged.specs.first(where: { $0.name == params.name }) else {
            throw WireError(
                code: .notFound,
                hint: "run: devctl status --json",
                message: "no server named '\(params.name)' is registered for \(params.project)"
            )
        }
        return await supervisor(project: params.project, spec: spec)
    }

    private func statusList(_ params: ProjectParams) async throws -> ServerListResult {
        /** An empty project means machine-wide (daemon restart, doctor, the app);
            machine-wide reads skip config errors rather than failing the sweep. */
        if params.project.isEmpty {
            var statuses: [ServerStatus] = []
            for project in await registry.allProjects() {
                var specs = (try? await mergedSpecs(project: project))?.specs
                if specs == nil {
                    specs = await registry.specs(project: project)
                }
                guard let specs else { continue }
                for spec in specs {
                    if let name = params.name, name != spec.name { continue }
                    let supervisor = await supervisor(project: project, spec: spec)
                    statuses.append(await supervisor.status())
                }
            }
            return ServerListResult(servers: statuses)
        }
        let merged = try await mergedSpecs(project: params.project)
        var statuses: [ServerStatus] = []
        for spec in merged.specs {
            if let name = params.name, name != spec.name { continue }
            let supervisor = await supervisor(project: params.project, spec: spec)
            statuses.append(await supervisor.status())
        }
        return ServerListResult(
            servers: statuses, trusted: await registry.isTrusted(project: params.project))
    }

    /** Wave-parallel group start honoring the dependency graph: a wave holds
        servers whose dependencies all settled in earlier waves. waitFor .started
        launches without blocking on health; the default blocks until healthy. */
    private func groupUp(_ params: GroupParams) async throws -> GroupResult {
        let merged = try await mergedSpecs(project: params.project)
        var wanted = merged.specs
        if let only = params.only, !only.isEmpty {
            /** --only pulls in transitive dependencies so the subset can boot. */
            var keep = Set(only)
            var changed = true
            while changed {
                changed = false
                for spec in wanted where keep.contains(spec.name) {
                    for dep in spec.dependsOn ?? [] where !keep.contains(dep) {
                        keep.insert(dep)
                        changed = true
                    }
                }
            }
            wanted = wanted.filter { keep.contains($0.name) }
        }
        for spec in wanted {
            await recordTrustIfNeeded(
                project: params.project, name: spec.name, fileNames: merged.fileNames)
        }
        guard case .success(let waves) = DependencyGraph.waves(specs: wanted) else {
            throw WireError(
                code: .configInvalid,
                hint: "run: devctl config check",
                message: "dependency cycle in devservers.json")
        }
        let specsByName = Dictionary(uniqueKeysWithValues: wanted.map { ($0.name, $0) })
        var results: [EnsureResult] = []
        var failed = false
        for wave in waves {
            if failed { break }
            let waveResults = await withTaskGroup(of: EnsureResult.self) { group in
                for name in wave {
                    guard let spec = specsByName[name] else { continue }
                    group.addTask { [weak self] in
                        guard let self else {
                            return EnsureResult(
                                reason: .stopped,
                                server: ServerStatus(logPath: "", phase: .stopped, project: params.project, server: name))
                        }
                        let supervisor = await self.supervisor(project: params.project, spec: spec)
                        if spec.waitFor == .started {
                            let status = await supervisor.start()
                            return EnsureResult(
                                reason: status.phase == .failed ? .failed : nil, server: status)
                        }
                        return await supervisor.ensure(timeoutSeconds: params.timeoutSeconds)
                    }
                }
                var collected: [EnsureResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: waveResults.sorted { $0.server.server < $1.server.server })
            if waveResults.contains(where: { $0.reason != nil }) {
                /** A broken wave stops the rollout; later waves depend on it. */
                failed = true
            }
        }
        return GroupResult(results: results)
    }

    /** Reverse-wave parallel stop. */
    private func groupDown(_ params: GroupParams) async throws -> GroupResult {
        let merged = try await mergedSpecs(project: params.project)
        guard case .success(let waves) = DependencyGraph.waves(specs: merged.specs) else {
            throw WireError(
                code: .configInvalid,
                hint: "run: devctl config check",
                message: "dependency cycle in devservers.json")
        }
        let specsByName = Dictionary(uniqueKeysWithValues: merged.specs.map { ($0.name, $0) })
        var results: [EnsureResult] = []
        for wave in waves.reversed() {
            let waveResults = await withTaskGroup(of: EnsureResult.self) { group in
                for name in wave {
                    guard let spec = specsByName[name] else { continue }
                    group.addTask { [weak self] in
                        guard let self else {
                            return EnsureResult(
                                server: ServerStatus(logPath: "", phase: .stopped, project: params.project, server: name))
                        }
                        let supervisor = await self.supervisor(project: params.project, spec: spec)
                        return EnsureResult(server: await supervisor.stop())
                    }
                }
                var collected: [EnsureResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: waveResults.sorted { $0.server.server < $1.server.server })
        }
        return GroupResult(results: results)
    }

    private func supervisor(project: String, spec: ServerSpec) async -> ServerSupervisor {
        let id = serverID(project: project, name: spec.name)
        if let existing = supervisors[id] {
            await existing.updateSpec(spec)
            return existing
        }
        let created = ServerSupervisor(
            events: events, launcher: launcher, paths: paths, projectPath: project,
            registry: registry, spec: spec)
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
