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
    /** Held resource locks keyed `project::resource`. Persisted to locks.json so
        a daemon crash mid-hold can still resume the paused servers when the
        holder is gone. Stale holders (dead pids) evaporate on access. */
    private var resourceLocks: [String: LockHolder] = [:]

    public init(launcher: any ProcessLauncher, paths: DevCtlPaths, registry: Registry) {
        self.events = EventStore(url: paths.eventsFile)
        self.launcher = launcher
        self.paths = paths
        self.registry = registry
        self.resourceLocks =
            Self.normalizedLocks(
                AtomicFile.loadDefensively(LocksFile.self, from: paths.locksFile)?.locks ?? [:])
    }

    private static func lockKey(project: String, resource: String) -> String {
        "\(canonicalProjectPath(project))::\(resource)"
    }

    private static func normalizedLocks(_ locks: [String: LockHolder]) -> [String: LockHolder] {
        var out: [String: LockHolder] = [:]
        for (key, holder) in locks {
            guard let separator = key.range(of: "::") else {
                out[key] = holder
                continue
            }
            let project = String(key[key.startIndex..<separator.lowerBound])
            let resource = String(key[separator.upperBound...])
            out[lockKey(project: project, resource: resource)] = holder
        }
        return out
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
                    try? Data().write(to: self.paths.stoppedIntentFile)
                    await self.exitDaemon()
                }
                return frame
            case .serverRegister:
                let request = try decoder.decode(WireRequest<RegisterParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                try await registry.register(project: project, spec: request.params.spec)
                let supervisor = await supervisor(project: project, spec: request.params.spec)
                await events.post(
                    kind: .registered, project: project, server: request.params.spec.name)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.status()))
            case .serverEnsure:
                let request = try decoder.decode(WireRequest<EnsureParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let target = ServerTargetParams(
                    name: request.params.name, port: request.params.port, project: project)
                let merged = try await mergedSpecs(project: project)
                let supervisor = try await resolvedSupervisor(target)
                await recordTrustIfNeeded(project: project, name: target.name, fileNames: merged.fileNames)
                if let spec = merged.specs.first(where: { $0.name == target.name }) {
                    try await lockGate(project: project, spec: spec)
                }
                try await prepareSpawn(target: target, supervisor: supervisor, portOverride: request.params.port)
                let result = await supervisor.ensure(timeoutSeconds: request.params.timeoutSeconds)
                DevCtlLog.daemon.info(
                    "ensure \(target.name)@\(project) -> \(result.server.phase.rawValue)")
                return try respond(id: head.id, result: result)
            case .serverStart:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let target = ServerTargetParams(
                    name: request.params.name, port: request.params.port, project: project)
                let merged = try await mergedSpecs(project: project)
                let supervisor = try await resolvedSupervisor(target)
                await recordTrustIfNeeded(
                    project: project, name: target.name, fileNames: merged.fileNames)
                if let spec = merged.specs.first(where: { $0.name == target.name }) {
                    try await lockGate(project: project, spec: spec)
                }
                try await prepareSpawn(target: target, supervisor: supervisor, portOverride: request.params.port)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.start()))
            case .serverStatus:
                let request = try decoder.decode(WireRequest<ProjectParams>.self, from: line)
                /** Empty project means machine-wide; do not canonicalize it or it
                    becomes the daemon cwd and the sweep never runs. */
                let project = request.params.project.isEmpty
                    ? ""
                    : canonicalProjectPath(request.params.project)
                let params = ProjectParams(name: request.params.name, project: project)
                return try respond(id: head.id, result: try await statusList(params))
            case .projectTrust:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                try await registry.setTrusted(
                    project: canonicalProjectPath(request.params.project))
                return try respond(id: head.id, result: WireEmpty())
            case .projectCheck:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let url = ProjectConfigLoader.configURL(project: project)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return try respond(
                        id: head.id,
                        result: CheckResult(
                            errors: [
                                "no devservers.json at \(url.path) (run: devctl config init)"
                            ]))
                }
                do {
                    guard let view = try ProjectConfigLoader.load(project: project) else {
                        return try respond(
                            id: head.id, result: CheckResult(errors: ["cannot read \(url.path)"]))
                    }
                    let hosts = await effectiveHosts(project: project, view: view)
                    return try respond(
                        id: head.id,
                        result: CheckResult(
                            effectiveHost: hosts.project.differs ? hosts.project.effective : nil,
                            effectiveHostReason: hosts.project.differs
                                ? hosts.project.reason : nil,
                            errors: view.errors,
                            host: view.host,
                            serverHosts: hosts.servers.isEmpty ? nil : hosts.servers,
                            servers: view.specs.map(\.name),
                            warnings: view.warnings))
                } catch let error as WireError {
                    return try respond(id: head.id, result: CheckResult(errors: [error.message]))
                }
            case .projectInitConfig:
                let request = try decoder.decode(WireRequest<InitConfigParams>.self, from: line)
                return try respond(id: head.id, result: try await initConfig(request.params))
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
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                return try respond(id: head.id, result: try await groupUp(params))
            case .groupDown:
                let request = try decoder.decode(WireRequest<GroupParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                return try respond(id: head.id, result: try await groupDown(params))
            case .serverStop:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let target = ServerTargetParams(
                    name: request.params.name, port: request.params.port,
                    project: canonicalProjectPath(request.params.project))
                let supervisor = try await resolvedSupervisor(target)
                let stopped = await supervisor.stop()
                DevCtlLog.daemon.info("stop \(target.name)@\(target.project)")
                return try respond(id: head.id, result: ServerResult(server: stopped))
            case .serverWait:
                let request = try decoder.decode(WireRequest<WaitParams>.self, from: line)
                let target = ServerTargetParams(
                    name: request.params.name,
                    project: canonicalProjectPath(request.params.project))
                let supervisor = try await resolvedSupervisor(target)
                let reason = await supervisor.wait(
                    for: request.params.condition, timeoutSeconds: request.params.timeoutSeconds)
                return try respond(
                    id: head.id, result: EnsureResult(reason: reason, server: await supervisor.status()))
            case .lockAcquire:
                let request = try decoder.decode(WireRequest<LockParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                let result = try await acquireLock(params)
                return try respond(id: head.id, result: result)
            case .lockStatus:
                let request = try decoder.decode(WireRequest<LockStatusParams>.self, from: line)
                let params = LockStatusParams(
                    project: canonicalProjectPath(request.params.project),
                    resource: request.params.resource)
                return try respond(id: head.id, result: await lockStatus(params))
            case .lockRelease:
                let request = try decoder.decode(WireRequest<LockParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                let result = try await releaseLock(params)
                return try respond(id: head.id, result: result)
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
                if let pattern = request.params.grep, let why = LogQuery.grepRejection(pattern) {
                    throw WireError(
                        code: .usage,
                        hint: "fix the pattern, or drop --grep to see every line",
                        message: "--grep is not a valid regular expression: \(why)")
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
                let merged = try await mergedSpecs(project: request.params.project)
                var statuses: [String: ServerStatus] = [:]
                var specsByName: [String: ServerSpec] = [:]
                for spec in merged.specs {
                    statuses[spec.name] = await annotatedStatus(
                        project: request.params.project, spec: spec)
                    specsByName[spec.name] = spec
                }
                let project = request.params.project
                let paths = self.paths
                let result = WhyEngine.diagnose(
                    target: request.params.name,
                    statuses: statuses,
                    specs: specsByName,
                    evidenceLines: { server in
                        let since =
                            statuses[server]?.lastExit?.at
                            ?? statuses[server]?.uptimeSec.map {
                                Date().addingTimeInterval(TimeInterval(-$0))
                            }
                        return LogQuery.run(
                            current: paths.structuredLogFile(project: project, server: server),
                            options: LogQueryOptions(
                                since: since, streams: [.err, .out, .sys], tail: 40)
                        ).map(\.contextLine)
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
        up to 7s grace each would blow through launchd's ExitTimeOut. The drain
        is not a deliberate stop: resume-on-boot intent survives so the next
        boot restores what was running. */
    public func drainAll() async {
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors.values {
                group.addTask { _ = await supervisor.stop(deliberate: false) }
            }
        }
    }

    /** Forget registered projects whose checkout path is gone: stop children,
        bounce orphan pids, drop registry/state/locks/supervisors. Opportunistic
        (boot + machine-wide status), not a watcher. */
    /** Forget registered projects whose checkout path is gone: stop children,
        bounce orphan pids, drop registry/state/locks/supervisors. Opportunistic
        (boot + machine-wide status), not a watcher. */
    public func pruneMissingProjects() async {
        for project in await registry.allProjects() {
            if FileManager.default.fileExists(atPath: project) { continue }
            await forgetMissingProject(project)
        }
    }

    /** Startup recovery: prune vanished checkouts first, reconcile persisted
        locks, then restore servers with boot intent. A recorded pid that is gone
        becomes crashed(daemon-restart); a live orphan (its spool fd kept it
        healthy while the daemon was away) is group-killed, since exit forensics
        are unknowable for non-children. Never adopted silently. What comes back:
        any server whose start intent survives (resumeOnBoot), which a machine
        shutdown's drain leaves set, plus the classic daemon-crash case of a
        phase left running/starting. A deliberate stop clears the flag, so only
        those stay down. Servers still paused under a live resource lock are left
        alone: starting them would fight the harness.

        Specs resolve through the merged view (devservers.json + ad-hoc registry),
        the same path ensure/status use. Config-defined servers are never written
        into registry.json, so a registry-only lookup would silently skip every
        committed server on boot. A rename/delete with no matching spec drops the
        orphaned state row instead of retrying forever. */
    public func recoverAtStartup() async {
        await pruneMissingProjects()
        await reconcileLocksAtStartup()
        var toStart: [(project: String, spec: ServerSpec)] = []
        for (id, persisted) in await registry.allPersistedState() {
            guard let separator = id.range(of: "::") else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
            let leftActive = persisted.phase == .running || persisted.phase == .starting
            let wantsRestore = persisted.resumeOnBoot ?? false
            guard persisted.pid != nil || leftActive || wantsRestore else { continue }
            if isPausedUnderLiveLock(project: project, name: name) {
                DevCtlLog.daemon.info(
                    "recover skip \(name)@\(project): paused under a live resource lock")
                continue
            }
            switch await resolveSpecForRecover(project: project, name: name) {
            case .missing:
                DevCtlLog.daemon.info(
                    "recover skip \(name)@\(project): no matching spec (renamed or removed)")
                try? await registry.removeState(serverID: id)
                continue
            case .unavailable:
                DevCtlLog.daemon.info(
                    "recover defer \(name)@\(project): config unreadable; keeping resume intent")
                continue
            case .found(let spec):
                if let pid = persisted.pid.map(pid_t.init),
                    let identity = ProcessTree.identity(of: pid)
                {
                    await bounceOrphan(identity, project: project, name: name)
                } else if leftActive {
                    await events.post(
                        kind: .crashed, project: project, server: name, detail: "daemon-restart")
                }
                try? await registry.updateState(serverID: id) { entry in
                    entry.lastExit = entry.lastExit ?? LastExit(at: Date())
                    entry.phase = .crashed
                    entry.pid = nil
                }
                if leftActive || wantsRestore {
                    toStart.append((project: project, spec: spec))
                }
            }
        }
        for item in toStart {
            let supervisor = await self.supervisor(project: item.project, spec: item.spec)
            do {
                try await self.prepareSpawn(
                    target: ServerTargetParams(name: item.spec.name, project: item.project),
                    supervisor: supervisor)
            } catch let error as WireError {
                DevCtlLog.daemon.error(
                    "recover skip \(item.spec.name)@\(item.project): \(error.message)")
                continue
            } catch {
                DevCtlLog.daemon.error(
                    "recover skip \(item.spec.name)@\(item.project): \(error.localizedDescription)")
                continue
            }
            DevCtlLog.daemon.info("recover start \(item.spec.name)@\(item.project)")
            _ = await supervisor.start()
        }
        /** Second pass: drop leftover rows for renamed/deleted servers even when
            they carry no resume intent (e.g. a deliberate stop under the old
            name). Only when the config is readable so a parse blip cannot wipe
            state. */
        for (id, _) in await registry.allPersistedState() {
            guard let separator = id.range(of: "::") else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
            if case .missing = await resolveSpecForRecover(project: project, name: name) {
                DevCtlLog.daemon.info("recover prune \(name)@\(project): orphaned state row")
                try? await registry.removeState(serverID: id)
            }
        }
    }

    /** Group-kill a live non-child left over from a prior daemon (or a prune that
        could not stop through the supervisor). Signals only while the snapshotted
        start time still matches: a recycled pid must not be killed. */
    private func bounceOrphan(
        _ root: ProcessIdentity, project: String, name: String
    ) async {
        guard ProcessTree.shouldSignal(
            snapshotted: root, live: ProcessTree.identity(of: root.pid))
        else {
            DevCtlLog.daemon.info(
                "orphan bounce skip \(name)@\(project): pid \(root.pid) gone or reused")
            return
        }
        let pid = root.pid
        let sweep = ProcessTree.descendants(of: pid)
        if case .failed(let code) = sweep {
            DevCtlLog.daemon.error(
                "orphan bounce descendant sweep failed (errno \(code)); group-only")
        }
        let descendants = sweep.identities
        ProcessTree.signalTree(
            descendants: descendants, revalidate: true, rootIdentity: root, rootPid: pid,
            signal: SIGTERM)
        /** Poll with identity, not kill(pid,0): a recycled number must end the
            wait as "gone" rather than escalate into the new process. */
        let graceDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < graceDeadline,
            ProcessTree.shouldSignal(
                snapshotted: root, live: ProcessTree.identity(of: pid))
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if ProcessTree.shouldSignal(
            snapshotted: root, live: ProcessTree.identity(of: pid))
        {
            ProcessTree.signalTree(
                descendants: descendants, revalidate: true, rootIdentity: root, rootPid: pid,
                signal: SIGKILL)
        }
        await events.post(
            kind: .crashed, project: project, server: name,
            detail: "daemon-restart: orphan pid \(pid) bounced")
    }

    /** Stop and forget one vanished checkout. Config is unreadable once the path
        is gone, so this walks supervisors + registry + state directly instead of
        groupDown / mergedSpecs. `project` must be the registry key as stored
        (already canonical at registration): re-canonicalizing a deleted path can
        change `/private/var` ↔ `/var` spelling and miss every lookup. */
    private func forgetMissingProject(_ project: String) async {
        let prefix = "\(project)::"
        /** Snapshot identities before teardown: a composite tree can outlive a
            no-op stop (phase already crashed/failed after the checkout vanished),
            so we keep the recorded ProcessIdentity and bounce only while that
            start time still matches. */
        var liveRoots: [(identity: ProcessIdentity, name: String)] = []
        var names = Set(await registry.specs(project: project).map(\.name))
        for (id, supervisor) in supervisors where id.hasPrefix(prefix) {
            guard let separator = id.range(of: "::") else { continue }
            let name = String(id[separator.upperBound...])
            names.insert(name)
            let status = await supervisor.status()
            if let pid = status.pid.map(pid_t.init),
                let identity = ProcessTree.identity(of: pid)
            {
                liveRoots.append((identity: identity, name: name))
            }
        }
        for (id, persisted) in await registry.allPersistedState() where id.hasPrefix(prefix) {
            guard let separator = id.range(of: "::") else { continue }
            let name = String(id[separator.upperBound...])
            names.insert(name)
            if let pid = persisted.pid.map(pid_t.init),
                let identity = ProcessTree.identity(of: pid),
                !liveRoots.contains(where: { $0.identity.pid == pid })
            {
                liveRoots.append((identity: identity, name: name))
            }
        }
        let sortedNames = names.sorted()
        DevCtlLog.daemon.info(
            "prune missing project \(project) (\(sortedNames.joined(separator: ",")))")
        for name in sortedNames {
            let id = serverID(project: project, name: name)
            if let supervisor = supervisors[id] {
                _ = await supervisor.stop()
                await events.post(
                    kind: .stopped, project: project, server: name, detail: "project path gone")
            }
            supervisors[id] = nil
        }
        for entry in liveRoots {
            guard ProcessTree.shouldSignal(
                snapshotted: entry.identity, live: ProcessTree.identity(of: entry.identity.pid))
            else { continue }
            await bounceOrphan(entry.identity, project: project, name: entry.name)
        }
        configCache[project] = nil
        let lockKeys = resourceLocks.keys.filter { $0.hasPrefix(prefix) }
        if !lockKeys.isEmpty {
            for key in lockKeys {
                resourceLocks[key] = nil
            }
            persistLocks()
        }
        try? await registry.removeState(forProject: project)
        try? await registry.removeProject(project)
        for name in sortedNames {
            await events.post(
                kind: .unregistered, project: project, server: name, detail: "project path gone")
        }
    }

    private enum RecoverSpec {
        case found(ServerSpec)
        /** Config loaded cleanly and the name is absent: rename/delete. */
        case missing
        /** Config threw (invalid JSON, etc.): keep intent for a later boot. */
        case unavailable
    }

    /** Prefer the merged config+registry view. Only treat a name as gone when
        the config is readable and does not contain it (and the registry does
        not either). A parse error must not drop resume-on-boot. */
    private func resolveSpecForRecover(project: String, name: String) async -> RecoverSpec {
        do {
            let merged = try await mergedSpecs(project: project)
            if let spec = merged.specs.first(where: { $0.name == name }) {
                return .found(spec)
            }
            return .missing
        } catch {
            if let spec = await registry.spec(project: project, name: name) {
                return .found(spec)
            }
            return .unavailable
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

    /** Resolve effective port, apply overlay/worktree host/materialization, and
        either auto-rebind a sibling conflict or refuse with port-held. Every
        start-shaped path routes through here. */
    /** Writes a devservers.json from what the daemon already knows, which is the
        only way back for a file that was gitignored and lost. The projection runs
        over the merged view, never a supervisor's spec: a running spec has been
        materialized, so its argv holds this machine's substituted port. */
    private func initConfig(_ params: InitConfigParams) async throws -> InitConfigResult {
        let project = canonicalProjectPath(params.project)
        let url = ProjectConfigLoader.configURL(project: project)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, params.mode == .create {
            throw WireError(
                code: .alreadyExists,
                hint: "run: devctl config init --force",
                message: "\(url.path) already exists; pass --force to replace it")
        }
        if exists, params.mode == .replace, params.force != true {
            throw WireError(
                code: .alreadyExists,
                hint: "run: devctl config init --force",
                message: "\(url.path) already exists; pass --force to replace it")
        }
        var specs: [ServerSpec] = []
        var host: String?
        if params.fromDaemon != false {
            if let merged = try? await mergedSpecs(project: project) {
                specs = merged.specs
                host = merged.host
            } else {
                specs = await registry.specs(project: project)
            }
        }
        for extra in params.servers ?? [] {
            specs.removeAll { $0.name == extra.name }
            specs.append(extra)
        }
        specs.sort { $0.name < $1.name }
        guard !specs.isEmpty else {
            throw WireError(
                code: .notFound,
                hint: "run: devctl register --name <name> --cmd <word>",
                message: "the daemon knows no servers for \(project), so there is nothing to write")
        }
        var config = ConfigProjection.file(
            host: params.host ?? host, project: project, specs: specs)
        var notRecovered: [String] = []
        if params.mode == .merge, exists {
            guard let existingData = try? Data(contentsOf: url),
                let existing = try? JSONCoding.decoder().decode(
                    ProjectFileConfig.self, from: existingData)
            else {
                throw WireError(
                    code: .configInvalid,
                    hint: "run: devctl config check",
                    message: "cannot parse \(url.path), so merging into it would lose it")
            }
            var merged = existing
            for (name, entry) in config.servers {
                guard let next = ConfigProjection.merge(
                    entry: entry, force: params.force == true, into: merged, name: name)
                else {
                    throw WireError(
                        code: .alreadyExists,
                        hint: "run: devctl register --name \(name) --write --force",
                        message: "\(url.path) already declares '\(name)'; pass --force to replace that entry")
                }
                merged = next
            }
            config = merged
        } else if exists {
            /** lifecycle exists only in the file and has no runtime counterpart,
                so a rewrite from daemon state drops it. Report it only when the
                file being replaced actually had one: naming a key the reader
                never wrote sends them looking for something that was never
                there. */
            let previous = (try? Data(contentsOf: url)).flatMap {
                try? JSONCoding.decoder().decode(ProjectFileConfig.self, from: $0)
            }
            if let lifecycle = previous?.lifecycle, !lifecycle.isEmpty, config.lifecycle == nil {
                notRecovered = ["lifecycle"]
            }
        }
        let view = ProjectConfigLoader.validate(config: config, project: project)
        guard view.errors.isEmpty else {
            throw WireError(
                code: .configInvalid,
                hint: "run: devctl config check",
                message: "the projected config does not validate: \(view.errors.joined(separator: "; "))")
        }
        let data = try JSONCoding.fileEncoder().encode(config)
        let content = String(decoding: data, as: UTF8.self) + "\n"
        let hosts = await effectiveHosts(project: project, view: view)
        let check = CheckResult(
            effectiveHost: hosts.project.differs ? hosts.project.effective : nil,
            effectiveHostReason: hosts.project.differs ? hosts.project.reason : nil,
            errors: view.errors,
            host: view.host,
            serverHosts: hosts.servers.isEmpty ? nil : hosts.servers,
            servers: view.specs.map(\.name),
            warnings: view.warnings)
        guard params.dryRun != true else {
            return InitConfigResult(
                check: check, content: content,
                notRecovered: notRecovered.isEmpty ? nil : notRecovered, path: url.path,
                written: false)
        }
        try AtomicFile.write(Data(content.utf8), to: url)
        configCache[project] = nil
        return InitConfigResult(
            check: check, content: content,
            notRecovered: notRecovered.isEmpty ? nil : notRecovered, path: url.path, written: true)
    }

    /** The hosts a spawn from this directory would use, answered before anything
        starts. Same resolver the spawn path runs, so `config check` can report a
        worktree's ephemeral origin rather than leaving it to be discovered as a
        broken app. Only servers that differ from the project are returned. */
    private func effectiveHosts(project: String, view: ProjectConfigView) async -> (
        project: EffectiveHost, servers: [EffectiveHost]
    ) {
        let defaultSlugHost = "\(ProjectConfigLoader.defaultSlug(project: project)).localhost"
        let preferred = CheckoutIdentity.preferredSubdomain(
            project: project, committedHost: view.host)
        let projectHost = EffectiveHostResolver.project(
            declaredHost: view.host,
            worktreeHost: CheckoutIdentity.worktreeHost(
                project: project, preferred: preferred, takenHosts: await takenHosts()))
        let overlay = LocalOverlay.load(project: project)
        let servers = view.specs.compactMap { spec -> EffectiveHost? in
            let resolved = EffectiveHostResolver.server(
                defaultSlugHost: defaultSlugHost, overlayHost: overlay?.servers?[spec.name]?.host,
                project: projectHost, server: spec.name, specHost: spec.host)
            return resolved.effective == projectHost.effective ? nil : resolved
        }
        return (projectHost, servers)
    }

    private func prepareSpawn(
        target: ServerTargetParams, supervisor: ServerSupervisor, portOverride: Int? = nil
    ) async throws {
        let current = await supervisor.status()
        switch current.phase {
        case .running, .starting, .stopping, .unhealthy:
            return
        case .crashed, .failed, .stopped:
            break
        }
        let merged = try await mergedSpecs(project: target.project)
        guard var spec = merged.specs.first(where: { $0.name == target.name }) else {
            throw WireError(
                code: .notFound,
                hint: "run: devctl status --json",
                message: "no server named '\(target.name)' in \(target.project)")
        }
        let overlay = LocalOverlay.load(project: target.project)
        let overlayServer = overlay?.servers?[target.name]
        spec = LocalOverlay.apply(spec: spec, overlay: overlayServer, project: target.project)
        let committedHost = merged.host
        let preferred = CheckoutIdentity.preferredSubdomain(
            project: target.project, committedHost: committedHost)
        let taken = await takenHosts()
        let defaultSlugHost =
            "\(ProjectConfigLoader.defaultSlug(project: target.project)).localhost"
        /** Host printed in committed urls/heads before any worktree swap; materialize
            matches against this so preferred-host URLs rewrite to the ephemeral
            label even after `spec.host` already moved. */
        let matchHost = spec.host ?? committedHost ?? defaultSlugHost
        let projectHost = EffectiveHostResolver.project(
            declaredHost: committedHost ?? defaultSlugHost,
            worktreeHost: CheckoutIdentity.worktreeHost(
                project: target.project, preferred: preferred, takenHosts: taken))
        let serverHost = EffectiveHostResolver.server(
            defaultSlugHost: defaultSlugHost, overlayHost: overlayServer?.host,
            project: projectHost, server: target.name, specHost: spec.host)
        /** Only a worktree swap rewrites the spec here: an overlay host is
            already applied above, and a per-server override keeps its own host.
            `config check` reads the same resolver, so the two cannot drift. */
        if serverHost.reason == .linkedWorktree {
            let worktreeHost = serverHost.effective
            spec.host = worktreeHost
            if let port = spec.port {
                let urlHost = URL(string: spec.url ?? "")?.host
                if spec.url == nil || urlHost == committedHost || urlHost == defaultSlugHost {
                    spec.url = "http://\(worktreeHost):\(port)/"
                }
            }
        }
        let declaredPort = spec.port
        let id = serverID(project: target.project, name: target.name)
        let persistedBound = await registry.persistedState(serverID: id)?.boundPort
        var effective =
            portOverride ?? overlayServer?.port ?? persistedBound ?? declaredPort
        var conflict: PortConflict?
        if let port = effective {
            let targetID = id
            let draft = PortClaim.resolve(spec: spec, effectivePort: port)
            guard let draftClaim = draft.claim, draft.error == nil else {
                throw WireError(
                    code: .configInvalid, hint: "run: devctl config check",
                    message: draft.error ?? "invalid port claim")
            }
            if let busy = await firstBusyPort(in: draftClaim, excluding: targetID) {
                let holder = await managedHolder(port: busy.port, excluding: targetID)
                if let holder, CheckoutIdentity.shareCommonDir(target.project, holder.project),
                    draftClaim.relative.contains(busy.port)
                {
                    let rebound = await allocateSiblingPort(
                        declared: declaredPort ?? port, excluding: targetID, project: target.project,
                        spec: spec)
                    conflict = PortConflict(
                        declaredPort: declaredPort ?? port,
                        effectivePort: rebound,
                        holder: "\(holder.server)@\(holder.project)",
                        message:
                            "port \(busy.port) held by sibling '\(holder.server)' in \(holder.project); rebound to \(rebound)",
                        state: .rebound)
                    effective = rebound
                    try? await registry.updateState(serverID: id) { $0.boundPort = rebound }
                } else if let holder {
                    DevCtlLog.daemon.error(
                        "port-held \(busy.port) by \(holder.server)@\(holder.project) for \(target.name)")
                    throw WireError(
                        code: .portHeld,
                        hint: "run: devctl stop \(holder.server) --project \(holder.project)",
                        message:
                            "port \(busy.port) is held by managed server '\(holder.server)' in \(holder.project)"
                    )
                } else if let squatter = PortGuard.listenerInfo(port: busy.port) {
                    throw WireError(
                        code: .portHeld,
                        hint: "run: kill \(squatter.pid)  (verify first: ps -p \(squatter.pid))",
                        message:
                            "port \(busy.port) is held by unmanaged pid \(squatter.pid) (\(squatter.command))"
                    )
                } else {
                    throw WireError(
                        code: .portHeld,
                        message: "port \(busy.port) already has a listener that devctl does not manage"
                    )
                }
            }
        }
        let resolved = PortClaim.resolve(spec: spec, effectivePort: effective)
        guard let claim = resolved.claim, resolved.error == nil else {
            throw WireError(
                code: .configInvalid, hint: "run: devctl config check",
                message: resolved.error ?? "invalid port claim")
        }
        if let busy = await firstBusyPort(in: claim, excluding: id) {
            throw WireError(
                code: .portHeld,
                message: "port \(busy.port) is still busy after rebind resolution")
        }
        let materialized = PortMaterializer.materialize(
            spec: spec, effectivePort: effective, effectiveHost: spec.host, matchHost: matchHost)
        await supervisor.updateSpec(materialized)
        await supervisor.setPortMeta(
            claim: claim, declaredPort: declaredPort, effectivePort: effective,
            portConflict: conflict)
    }

    /** First claimed port that is held (managed or unmanaged). Absolutes and
        relatives are treated the same for freeness; only sibling rebind cares
        which set a conflict came from. */
    private func firstBusyPort(in claim: PortClaim, excluding targetID: String) async -> (
        port: Int, managed: Bool
    )? {
        for port in claim.allPorts {
            if await managedHolder(port: port, excluding: targetID) != nil {
                return (port: port, managed: true)
            }
            if PortGuard.isListening(port: port) {
                return (port: port, managed: false)
            }
        }
        return nil
    }

    private func allocateSiblingPort(
        declared: Int, excluding: String, project: String, spec: ServerSpec
    ) async -> Int {
        var candidate = CheckoutIdentity.siblingPortCandidate(declared: declared, project: project)
        for _ in 0..<200 {
            let resolved = PortClaim.resolve(spec: spec, effectivePort: candidate)
            if let claim = resolved.claim, resolved.error == nil,
                await firstBusyPort(in: claim, excluding: excluding) == nil
            {
                return candidate
            }
            candidate += 1
            if candidate > 65_000 { candidate = 10_000 }
        }
        return candidate
    }

    /** Wait until every claimed port is free, or return the first still-busy port. */
    private func waitForClaimFree(claim: PortClaim, budgetSeconds: Double = 2) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(budgetSeconds))
        while true {
            var busy: Int?
            for port in claim.allPorts where PortGuard.isListening(port: port) {
                busy = port
                break
            }
            if busy == nil { return nil }
            if ContinuousClock.now >= deadline { return busy }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func takenHosts() async -> Set<String> {
        var hosts: Set<String> = []
        for project in await registry.allProjects() {
            if let view = try? loadConfig(project: project) {
                hosts.insert(view.host)
                for spec in view.specs {
                    if let host = spec.host { hosts.insert(host) }
                    if let url = spec.url, let host = URL(string: url)?.host {
                        hosts.insert(host)
                    }
                }
            }
        }
        return hosts
    }

    /** Which managed server holds `port`, if any. The resident supervisor pool
        answers for servers this daemon has been asked about; state.json answers
        for the rest, since the pool is built lazily and a server started before
        this daemon's first request for it has no entry there at all. A persisted
        row counts only while its recorded pid is still alive. */
    private func managedHolder(port: Int, excluding targetID: String) async -> (
        project: String, server: String
    )? {
        for (id, other) in supervisors where id != targetID {
            let status = await other.status()
            let active =
                status.phase == .running || status.phase == .starting || status.phase == .unhealthy
            if active,
                status.effectivePort == port || status.declaredPort == port
                    || status.observedPort == port
                    || (status.ports?.values.contains(port) ?? false)
            {
                return (project: status.project, server: status.server)
            }
        }
        for (id, persisted) in await registry.allPersistedState() where id != targetID {
            guard supervisors[id] == nil else { continue }
            let active =
                persisted.phase == .running || persisted.phase == .starting
                || persisted.phase == .unhealthy
            guard active, let pid = persisted.pid.map(pid_t.init), kill(pid, 0) == 0 else {
                continue
            }
            guard let separator = id.range(of: "::") else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
            guard let merged = try? await mergedSpecs(project: project),
                let spec = merged.specs.first(where: { $0.name == name })
            else { continue }
            let bound = persisted.boundPort ?? spec.port
            let resolved = PortClaim.resolve(spec: spec, effectivePort: bound)
            if let claim = resolved.claim, claim.allPorts.contains(port) {
                return (project: project, server: name)
            }
            guard bound == port else { continue }
            return (project: project, server: name)
        }
        return nil
    }

    /** The merged project view: committed devservers.json specs (source of
        truth for their names) plus ad-hoc registry entries. Throws
        config-invalid when the file exists but cannot be used. */
    private func mergedSpecs(project: String) async throws -> (
        host: String?, specs: [ServerSpec], fileNames: Set<String>
    ) {
        let project = canonicalProjectPath(project)
        var specs: [String: ServerSpec] = [:]
        for spec in await registry.specs(project: project) {
            specs[spec.name] = spec
        }
        var fileNames: Set<String> = []
        var host: String?
        if let view = try loadConfig(project: project) {
            guard view.errors.isEmpty else {
                throw WireError(
                    code: .configInvalid,
                    hint: "run: devctl config check",
                    message: "devservers.json is invalid: \(view.errors.joined(separator: "; "))")
            }
            host = view.host
            for spec in view.specs {
                specs[spec.name] = spec
                fileNames.insert(spec.name)
            }
        }
        return (
            host: host, specs: specs.values.sorted { $0.name < $1.name }, fileNames: fileNames
        )
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

    /** Acquire: refuse if another live holder owns it, pause active declarers
        without retiring boot intent, persist the hold, return who was paused. */
    private func acquireLock(_ params: LockParams) async throws -> LockResult {
        let key = Self.lockKey(project: params.project, resource: params.resource)
        await releaseOrphanedLock(key: key)
        if let holder = resourceLocks[key], holder.pid != params.holderPid {
            throw WireError(
                code: .resourceLocked,
                hint: "wait for pid \(holder.pid) to finish, or verify it: ps -p \(holder.pid)",
                message:
                    "resource '\(params.resource)' is locked by pid \(holder.pid) since \(JSONCoding.formatISO8601(holder.since))"
            )
        }
        /** Same holder re-acquiring (retry after a blip) keeps the existing pause
            set rather than double-stopping, and must answer with everything the
            first acquire did: dropping `live` or `statePath` here would leave the
            retrying client unable to judge the resource for the rest of the hold. */
        if let existing = resourceLocks[key], existing.pid == params.holderPid {
            let specs = (try? await mergedSpecs(project: params.project))?.specs ?? []
            return LockResult(
                live: existing.live, paused: existing.paused,
                statePath: try LockResource.statePath(
                    project: params.project, resource: params.resource, specs: specs))
        }
        var live: [String] = []
        var paused: [String] = []
        let shouldPause = params.pause ?? true
        let merged = try? await mergedSpecs(project: params.project)
        for spec in merged?.specs ?? []
        where LockResource.declares(resource: params.resource, spec: spec) {
            let supervisor = await supervisor(project: params.project, spec: spec)
            let status = await supervisor.status()
            switch status.phase {
            case .running, .starting, .unhealthy, .stopping:
                guard shouldPause else {
                    /** Sound for the whole hold: lockGate refuses to start a
                        declarer while a live holder owns the resource, so this
                        set can only shrink. */
                    live.append(spec.name)
                    continue
                }
                /** Non-retiring stop: boot intent survives so a daemon crash
                    mid-hold can still bring the server back if the holder is gone. */
                _ = await supervisor.stop(deliberate: false)
                paused.append(spec.name)
                DevCtlLog.daemon.info(
                    "lock \(params.resource) paused \(spec.name)@\(params.project)")
            case .stopped, .crashed, .failed:
                break
            }
        }
        live.sort()
        paused.sort()
        /** Refusing here is correct when devctl cannot tell which state the lock
            guards: taking it anyway would report on the wrong file. */
        let statePath = try LockResource.statePath(
            project: params.project, resource: params.resource, specs: merged?.specs ?? [])
        resourceLocks[key] = LockHolder(
            live: live.isEmpty ? nil : live, pause: shouldPause, paused: paused,
            pid: params.holderPid, resumeTimeoutSeconds: params.resumeTimeoutSeconds, since: Date())
        persistLocks()
        return LockResult(
            live: live.isEmpty ? nil : live, paused: paused, statePath: statePath)
    }

    /** Who holds a resource right now, if anyone. A dead holder is released
        first, so a stale row reads as no holder rather than as a phantom the
        caller then waits on. */
    private func lockStatus(_ params: LockStatusParams) async -> LockStatusResult {
        let key = Self.lockKey(project: params.project, resource: params.resource)
        await releaseOrphanedLock(key: key)
        return LockStatusResult(holder: resourceLocks[key])
    }

    /** Release: only the matching holder clears the lock; then ensure everyone
        that was paused. */
    private func releaseLock(_ params: LockParams) async throws -> LockResult {
        let key = Self.lockKey(project: params.project, resource: params.resource)
        guard let holder = resourceLocks[key], holder.pid == params.holderPid else {
            return LockResult(paused: [])
        }
        resourceLocks[key] = nil
        persistLocks()
        let timeout = params.resumeTimeoutSeconds ?? holder.resumeTimeoutSeconds ?? 60
        await resumePaused(
            names: holder.paused, project: params.project, resource: params.resource,
            timeoutSeconds: timeout)
        return LockResult(paused: holder.paused)
    }

    /** Drop dead holders and resume what they paused. Called from gate/acquire
        and at startup so a crashed harness (or a dead CLI after a daemon bounce)
        never leaves servers stopped. */
    private func releaseOrphanedLock(key: String) async {
        guard let holder = resourceLocks[key] else { return }
        guard kill(pid_t(holder.pid), 0) != 0 else { return }
        guard let separator = key.range(of: "::") else {
            resourceLocks[key] = nil
            persistLocks()
            return
        }
        let project = String(key[key.startIndex..<separator.lowerBound])
        let resource = String(key[separator.upperBound...])
        DevCtlLog.daemon.info(
            "lock \(resource) holder pid \(holder.pid) is gone; resuming \(holder.paused.joined(separator: ","))"
        )
        resourceLocks[key] = nil
        persistLocks()
        await resumePaused(
            names: holder.paused, project: project, resource: resource,
            timeoutSeconds: holder.resumeTimeoutSeconds ?? 60)
    }

    private func resumePaused(
        names: [String], project: String, resource: String, timeoutSeconds: Double
    ) async {
        guard !project.isEmpty else { return }
        for name in names {
            do {
                let merged = try await mergedSpecs(project: project)
                guard let spec = merged.specs.first(where: { $0.name == name }) else { continue }
                let supervisor = await supervisor(project: project, spec: spec)
                let id = serverID(project: project, name: name)
                let bound = await registry.persistedState(serverID: id)?.boundPort ?? spec.port
                let resolved = PortClaim.resolve(spec: spec, effectivePort: bound)
                if let claim = resolved.claim, let busy = await waitForClaimFree(claim: claim) {
                    DevCtlLog.daemon.error(
                        "lock \(resource) resume refused \(name)@\(project): port \(busy) still busy")
                    continue
                }
                try await prepareSpawn(
                    target: ServerTargetParams(name: name, project: project), supervisor: supervisor)
                _ = await supervisor.ensure(timeoutSeconds: timeoutSeconds)
                DevCtlLog.daemon.info("lock \(resource) resumed \(name)@\(project)")
            } catch let error as WireError {
                DevCtlLog.daemon.error(
                    "lock \(resource) could not resume \(name)@\(project): \(error.message)")
            } catch {
                DevCtlLog.daemon.error(
                    "lock \(resource) could not resume \(name)@\(project): \(error.localizedDescription)"
                )
            }
        }
    }

    /** At boot: dead holders resume their paused set; live holders stay loaded
        so lockGate still refuses starts under the harness. */
    private func reconcileLocksAtStartup() async {
        let keys = Array(resourceLocks.keys)
        for key in keys {
            await releaseOrphanedLock(key: key)
        }
        if !resourceLocks.isEmpty {
            DevCtlLog.daemon.info(
                "rehydrated \(resourceLocks.count) live resource lock(s) after restart")
        }
    }

    private func isPausedUnderLiveLock(project: String, name: String) -> Bool {
        let prefix = "\(canonicalProjectPath(project))::"
        for (key, holder) in resourceLocks {
            guard key.hasPrefix(prefix) else { continue }
            guard kill(pid_t(holder.pid), 0) == 0 else { continue }
            if holder.paused.contains(name) { return true }
        }
        return false
    }

    private func persistLocks() {
        /** Empty file is fine: defensive load treats missing/corrupt as {}. */
        try? AtomicFile.write(
            JSONCoding.encoder().encode(LocksFile(locks: resourceLocks)), to: paths.locksFile)
    }

    /** Refuses to start a server while an external holder owns one of its
        declared resources: restarting mid-harness-run is exactly the contention
        the lock exists to prevent. */
    private func lockGate(project: String, spec: ServerSpec) async throws {
        for declaration in spec.locks ?? [] {
            let resource = declaration.name
            let key = Self.lockKey(project: project, resource: resource)
            await releaseOrphanedLock(key: key)
            if let holder = resourceLocks[key] {
                throw WireError(
                    code: .resourceLocked,
                    hint: "the holder releases it when done; check: ps -p \(holder.pid)",
                    message:
                        "server '\(spec.name)' holds resource '\(resource)', locked by pid \(holder.pid) since \(JSONCoding.formatISO8601(holder.since))"
                )
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
            await pruneMissingProjects()
            var statuses: [ServerStatus] = []
            for project in await registry.allProjects() {
                var specs = (try? await mergedSpecs(project: project))?.specs
                if specs == nil {
                    specs = await registry.specs(project: project)
                }
                guard let specs else { continue }
                for spec in specs {
                    if let name = params.name, name != spec.name { continue }
                    statuses.append(await annotatedStatus(project: project, spec: spec))
                }
            }
            return ServerListResult(servers: statuses)
        }
        let merged = try await mergedSpecs(project: params.project)
        var statuses: [ServerStatus] = []
        for spec in merged.specs {
            if let name = params.name, name != spec.name { continue }
            statuses.append(await annotatedStatus(project: params.project, spec: spec))
        }
        return ServerListResult(
            servers: statuses, trusted: await registry.isTrusted(project: params.project))
    }

    /** The supported way to read a status for a response: every reader gets the
        latent-port-conflict annotation. A handler that calls `supervisor.status()`
        directly reports a stopped server without naming the holder keeping it
        down, so route status reads through here. */
    private func annotatedStatus(project: String, spec: ServerSpec) async -> ServerStatus {
        let status = await supervisor(project: project, spec: spec).status()
        return await annotateLatentPortConflict(
            status, excluding: serverID(project: project, name: spec.name))
    }

    /** When a server is not up but its declared port is held, surface a latent
        conflict so session context warns before the agent runs ensure. */
    private func annotateLatentPortConflict(_ status: ServerStatus, excluding: String) async -> ServerStatus {
        guard status.portConflict == nil else { return status }
        switch status.phase {
        case .stopped, .crashed, .failed:
            break
        case .running, .starting, .stopping, .unhealthy:
            return status
        }
        guard let port = status.declaredPort ?? status.effectivePort else { return status }
        var annotated = status
        if let holder = await managedHolder(port: port, excluding: excluding) {
            let sibling = CheckoutIdentity.shareCommonDir(status.project, holder.project)
            annotated.portConflict = PortConflict(
                declaredPort: port,
                holder: "\(holder.server)@\(holder.project)",
                message: sibling
                    ? "port \(port) held by sibling '\(holder.server)' in \(holder.project); ensure will auto-rebind"
                    : "port \(port) held by '\(holder.server)' in \(holder.project); run: devctl stop \(holder.server) --project \(holder.project)",
                state: .held)
        } else if PortGuard.isListening(port: port) {
            let detail = PortGuard.listenerInfo(port: port).map {
                "unmanaged pid \($0.pid) (\($0.command))"
            } ?? "an unmanaged listener"
            annotated.portConflict = PortConflict(
                declaredPort: port,
                holder: detail,
                message: "port \(port) held by \(detail)",
                state: .held)
        }
        return annotated
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
        /** Port ownership is checked for the whole set before anything spawns, so
            a held port refuses the rollout instead of leaving half a project up
            next to a server that lost a race it never knew it entered. Servers
            already up skip the check against their own listeners. */
        /** Hold the prepared supervisors rather than re-resolving them per wave.
            `supervisor(project:spec:)` re-applies the committed spec to anything
            not yet up, which would discard exactly what prepareSpawn just wrote:
            the rebound port, the worktree host, the substituted argv, and the
            injected env. A second lookup here spawned the child on the committed
            port while status reported the rebind. */
        var prepared: [String: ServerSupervisor] = [:]
        for spec in wanted {
            let target = ServerTargetParams(
                name: spec.name, port: params.port, project: params.project)
            let supervisor = await supervisor(project: params.project, spec: spec)
            try await prepareSpawn(
                target: target, supervisor: supervisor, portOverride: params.port)
            prepared[spec.name] = supervisor
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
                    guard let spec = specsByName[name], let supervisor = prepared[name] else {
                        continue
                    }
                    group.addTask {
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
        let project = canonicalProjectPath(project)
        let id = serverID(project: project, name: spec.name)
        if let existing = supervisors[id] {
            /** A live run holds a materialized spawn spec (effective port, worktree
                host, rewritten url). Re-resolving committed config for status must
                not clobber that, or agents see the declared origin and a false
                "config changed since start". */
            switch await existing.status().phase {
            case .running, .starting, .unhealthy, .stopping:
                break
            case .stopped, .crashed, .failed:
                await existing.updateSpec(spec)
            }
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
    private let socketPath: String

    public init(router: Router, socketPath: String) throws {
        self.router = router
        self.socketPath = socketPath
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
    }

    /** `onReady` fires when the listener is actually accepting, which is not
        when this returns: `NWListener.start` is asynchronous, and the socket
        path is unlinked during init and only recreated on the way to `.ready`.
        Announcing readiness on the next statement therefore told clients the
        daemon was up while a connect still got ENOENT, which is how a readiness
        check comes to pass for the wrong reason. */
    public func start(onReady: @escaping @Sendable () -> Void = {}) {
        let socketPath = self.socketPath
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                /** Owner-only, and it has to run here: the socket file does not
                    exist until the listener is ready, so a chmod any earlier
                    targets an empty path and silently does nothing. The
                    containing directory is 0700, making this the second layer
                    rather than the only one. */
                if chmod(socketPath, 0o600) != 0 {
                    DevCtlLog.daemon.error(
                        "cannot restrict the control socket to owner-only: errno \(errno)")
                }
                onReady()
            case .failed(let error):
                DevCtlLog.daemon.error("control listener failed: \(String(describing: error))")
            case .cancelled:
                DevCtlLog.daemon.debug("control listener cancelled")
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "devctl.control"))
    }

    /** A client that exits without a shutdown handshake (every one-shot `devctl`
        invocation) surfaces as `.failed` with a peer-close errno. Those are
        routine, so they log at debug; anything else is a real listener problem
        and stays at error. */
    private static func isRoutineDisconnect(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .ENETDOWN || code == .ECONNRESET || code == .EPIPE || code == .ECANCELED
    }

    private static func serve(connection: NWConnection, router: Router) {
        let queue = DispatchQueue(label: "devctl.connection")
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                if isRoutineDisconnect(error) {
                    DevCtlLog.daemon.debug("control connection closed by peer: \(String(describing: error))")
                } else {
                    DevCtlLog.daemon.error("control connection failed: \(String(describing: error))")
                }
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
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
