import DevCtlKit
import Foundation

/** One actor per server: owns the child's lifecycle and serializes every mutation,
    which is what makes `ensure` single-flight (concurrent starts join the same
    in-flight attempt instead of double-spawning). */
public actor ServerSupervisor {
    public let projectPath: String

    private var consecutiveFailures = 0
    private var errTailer: SpoolTailer?
    private let events: EventStore?
    private let logStore: LogStore
    private var outTailer: SpoolTailer?
    private var consecutiveSuccesses = 0
    private var everHealthy = false
    private var healthTask: Task<Void, Never>?
    private var lastExit: LastExit?
    private var lastHealthAt: Date?
    private let launcher: any ProcessLauncher
    private var observedPort: Int?
    private let paths: DevCtlPaths
    private var phase: ServerPhase = .stopped
    private var pid: pid_t?
    private let prober: any HealthProber
    private let registry: Registry
    private var runningSpecHash: String?
    private var runTask: Task<Void, Never>?
    private var spawnError: SpawnError?
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []
    private var spec: ServerSpec
    private var startedAt: Date?
    private var stopRequested = false

    public init(
        events: EventStore? = nil,
        launcher: any ProcessLauncher,
        paths: DevCtlPaths,
        prober: any HealthProber = NetworkHealthProber(),
        projectPath: String,
        registry: Registry,
        spec: ServerSpec
    ) {
        self.events = events
        self.launcher = launcher
        self.logStore = LogStore(currentURL: paths.structuredLogFile(project: projectPath, server: spec.name))
        self.paths = paths
        self.prober = prober
        self.projectPath = projectPath
        self.registry = registry
        self.spec = spec
        if let persisted = AtomicFile.loadDefensively(StateFile.self, from: paths.stateFile)?
            .servers[serverID(project: projectPath, name: spec.name)] {
            self.lastExit = persisted.lastExit
            self.spawnError = persisted.spawnError
            if persisted.phase == .crashed || persisted.phase == .failed {
                self.phase = persisted.phase
            }
        }
    }

    public func updateSpec(_ newSpec: ServerSpec) {
        spec = newSpec
    }

    /** Starts the server if not already starting/running; otherwise joins the
        in-flight attempt. Returns once a pid exists or the spawn has failed; the
        phase stays `starting` until the healthcheck passes. */
    public func start() async -> ServerStatus {
        switch phase {
        case .running, .unhealthy:
            return status()
        case .starting:
            await waitForSpawnSettled()
            return status()
        case .stopping:
            await waitForRunTaskCompletion()
            return await start()
        case .crashed, .failed, .stopped:
            break
        }
        phase = .starting
        stopRequested = false
        spawnError = nil
        everHealthy = false
        observedPort = nil
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        runningSpecHash = Self.specHash(spec)
        let id = serverID(project: projectPath, name: spec.name)
        let argv = effectiveArgv()
        let cwd = effectiveCwd()
        let environment = spec.env ?? [:]
        let outURL = paths.spoolOutFile(project: projectPath, server: spec.name)
        let errURL = paths.spoolErrFile(project: projectPath, server: spec.name)
        do {
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            await recordSpawnFailure(SpawnError(errno: nil, message: "cannot create log directory: \(error)"), id: id)
            return status()
        }
        let outFD = open(outURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        let errFD = open(errURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0, errFD >= 0 else {
            if outFD >= 0 { close(outFD) }
            if errFD >= 0 { close(errFD) }
            await recordSpawnFailure(
                SpawnError(errno: Int(errno), message: "cannot open spool: \(String(cString: strerror(errno)))"),
                id: id)
            return status()
        }
        runTask = Task { [launcher] in
            let outcome = await launcher.run(
                argv: argv,
                cwd: cwd,
                environment: environment,
                stdoutFD: outFD,
                stderrFD: errFD,
                onSpawn: { [weak self] childPid in
                    await self?.recordSpawn(pid: childPid, id: id)
                }
            )
            close(outFD)
            close(errFD)
            await self.recordOutcome(outcome, id: id)
        }
        await waitForSpawnSettled()
        return status()
    }

    /** The ensure state matrix: stopped/crashed/failed start fresh; starting joins
        the in-flight attempt; running and unhealthy are no-ops (unhealthy is
        reported, not restarted). Blocks until healthy, terminal, or timeout. */
    public func ensure(timeoutSeconds: Double) async -> EnsureResult {
        switch phase {
        case .running, .unhealthy:
            return EnsureResult(server: status())
        case .starting:
            break
        case .stopping:
            await waitForRunTaskCompletion()
            return await ensure(timeoutSeconds: timeoutSeconds)
        case .crashed, .failed, .stopped:
            let started = await start()
            if started.phase == .failed {
                return EnsureResult(reason: .failed, server: started)
            }
        }
        let outcome = await wait(for: .healthy, timeoutSeconds: timeoutSeconds)
        return EnsureResult(reason: outcome, server: status())
    }

    /** Blocks until the condition holds. Rides through non-terminal transitions
        (another session's restart) and fails fast on crashed/failed/stopped. */
    public func wait(for condition: WaitCondition, timeoutSeconds: Double) async -> EnsureReason? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while true {
            switch condition {
            case .healthy:
                if phase == .running { return nil }
                if phase == .crashed { return .crashed }
                if phase == .failed { return .failed }
                if phase == .stopped { return .stopped }
            case .stopped:
                if phase == .stopped || phase == .crashed || phase == .failed { return nil }
            }
            if ContinuousClock.now >= deadline { return .timeout }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /** SIGTERM to the process group plus every stray descendant, grace period,
        then SIGKILL the same way. The session created at spawn makes pgid == pid,
        but children that setpgid/setsid themselves (Foundation Process does this
        by default) escape the group, so teardown also sweeps the descendant tree,
        snapshotted before the first signal since orphans reparent to launchd. */
    public func stop(graceSeconds: Double = 7) async -> ServerStatus {
        switch phase {
        case .stopped, .crashed, .failed:
            return status()
        case .stopping:
            await waitForRunTaskCompletion()
            return status()
        case .starting, .running, .unhealthy:
            break
        }
        guard let target = pid else {
            phase = .stopped
            return status()
        }
        stopRequested = true
        phase = .stopping
        let snapshot = ProcessTree.descendants(of: target)
        ProcessTree.signalTree(rootPid: target, descendants: snapshot, signal: SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if runTask == nil { break }
            if kill(target, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        /** Escalate: the pre-signal snapshot plus a fresh sweep (new children may
            have appeared during the grace window while the parent lived). */
        let escalation = Set(snapshot).union(ProcessTree.descendants(of: target))
        if kill(target, 0) == 0 {
            ProcessTree.signalTree(rootPid: target, descendants: Array(escalation), signal: SIGKILL)
        } else {
            for pid in escalation where kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        await waitForRunTaskCompletion()
        return status()
    }

    public func status() -> ServerStatus {
        let check = EffectiveHealthcheck.resolve(spec: spec)
        let terminal = phase == .crashed || phase == .failed
        return ServerStatus(
            declaredPort: spec.port,
            heads: spec.heads,
            healthcheck: check.kind,
            icon: spec.icon,
            lastExit: lastExit,
            lastHealthAt: lastHealthAt,
            logPath: paths.structuredLogFile(project: projectPath, server: spec.name).path,
            observedPort: observedPort,
            phase: phase,
            pid: pid.map(Int.init),
            project: projectPath,
            recentLogTail: terminal ? spoolTail() : nil,
            server: spec.name,
            spawnError: spawnError,
            specStale: specStaleFlag(),
            uptimeSec: startedAt.map { Int(Date().timeIntervalSince($0)) },
            url: spec.url
        )
    }

    // MARK: - Health monitoring

    private func startHealthMonitor() {
        healthTask?.cancel()
        let check = EffectiveHealthcheck.resolve(spec: spec)
        let intervalMs = spec.healthcheck?.intervalMs ?? 2000
        let initialDelayMs: Int
        if case .none(let stabilizationMs) = check {
            initialDelayMs = stabilizationMs
        } else {
            initialDelayMs = 200
        }
        healthTask = Task { [prober, weak self] in
            try? await Task.sleep(for: .milliseconds(initialDelayMs))
            while !Task.isCancelled {
                let policy = await PowerState.shared.probePolicy()
                if case .skip = policy {
                    try? await Task.sleep(for: .milliseconds(intervalMs))
                    continue
                }
                let healthy = await prober.probe(check)
                guard !Task.isCancelled else { return }
                /** Failures inside the wake grace window carry no signal: the
                    machine (and the server) just woke up. */
                if case .ignoreFailures = policy, !healthy {
                    try? await Task.sleep(for: .milliseconds(intervalMs))
                    continue
                }
                await self?.recordProbe(success: healthy)
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    private func recordProbe(success: Bool) {
        /** Probes landing after the process died must not resurrect state. */
        guard phase == .starting || phase == .running || phase == .unhealthy else { return }
        let healthyAfter = spec.healthcheck?.healthyAfter ?? 1
        let unhealthyAfter = spec.healthcheck?.unhealthyAfter ?? 3
        if success {
            consecutiveSuccesses += 1
            consecutiveFailures = 0
            lastHealthAt = Date()
            if !everHealthy {
                if consecutiveSuccesses >= healthyAfter {
                    everHealthy = true
                    phase = .running
                    scanObservedPort()
                    postHealthEvent(.healthy)
                }
            } else if phase == .unhealthy {
                phase = .running
                postHealthEvent(.healthy)
            }
        } else {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            /** unhealthyAfter applies only after first-healthy: a slow boot is
                `starting` until the deadline callers chose, never `unhealthy`. */
            if everHealthy, phase == .running, consecutiveFailures >= unhealthyAfter {
                phase = .unhealthy
                postHealthEvent(.unhealthy)
            }
        }
    }

    /** Post-healthy listen scan: dev servers auto-increment ports on conflict
        (Vite, Next), so the port actually listening is surfaced separately from
        the declared one. */
    private func scanObservedPort() {
        guard let rootPid = pid else { return }
        Task { [weak self] in
            let pids = [rootPid] + ProcessTree.descendants(of: rootPid)
            let ports = PortGuard.listeningPorts(pids: pids)
            await self?.recordObservedPort(ports: ports)
        }
    }

    private func recordObservedPort(ports: [Int]) {
        guard !ports.isEmpty else { return }
        if let declared = spec.port, ports.contains(declared) {
            observedPort = declared
        } else {
            observedPort = ports.first
        }
    }

    /** Log access for the router: queries and marks flow through the store so
        ordering against process output is exact. */
    public func logQuery(_ options: LogQueryOptions) async -> [LogRecord] {
        await logStore.query(options)
    }

    public func placeMark(label: String, text: String) async -> PlacedMark {
        let mark = await logStore.appendMark(label: label, text: text)
        await events?.post(kind: .marked, project: projectPath, server: spec.name, detail: "\(mark.id) \(text)")
        return PlacedMark(at: mark.at, id: mark.id, server: spec.name)
    }

    public func resolveMark(_ markID: String) async -> Date? {
        await logStore.resolveMark(markID)
    }

    public func currentSpec() -> ServerSpec {
        spec
    }

    private func postHealthEvent(_ kind: EventKind) {
        Task { [events, projectPath, name = spec.name] in
            await events?.post(kind: kind, project: projectPath, server: name)
        }
    }

    // MARK: - Internal bookkeeping

    private func effectiveArgv() -> [String] {
        if spec.shell == true {
            return ["/bin/zsh", "-lc", spec.command.joined(separator: " ")]
        }
        return spec.command
    }

    private func effectiveCwd() -> String {
        guard let cwd = spec.cwd, !cwd.isEmpty, cwd != "." else { return projectPath }
        return (projectPath as NSString).appendingPathComponent(cwd)
    }

    private func recordSpawn(pid childPid: pid_t, id: String) async {
        pid = childPid
        let spawnedAt = Date()
        startedAt = spawnedAt
        let out = SpoolTailer(
            store: logStore, stream: .out,
            url: paths.spoolOutFile(project: projectPath, server: spec.name))
        let err = SpoolTailer(
            store: logStore, stream: .err,
            url: paths.spoolErrFile(project: projectPath, server: spec.name))
        outTailer = out
        errTailer = err
        await out.start()
        await err.start()
        await logStore.append(stream: .sys, text: "started pid=\(childPid)")
        await events?.post(kind: .started, project: projectPath, server: spec.name, detail: "pid \(childPid)")
        startHealthMonitor()
        await registryUpdate(id: id) { entry in
            entry.lastExit = nil
            entry.phase = .starting
            entry.pid = Int(childPid)
            entry.spawnError = nil
            entry.startedAt = spawnedAt
        }
        settleSpawnWaiters()
    }

    private func recordSpawnFailure(_ error: SpawnError, id: String) async {
        spawnError = error
        phase = .failed
        await logStore.append(stream: .sys, text: "spawn failed: \(error.message)")
        await events?.post(kind: .failed, project: projectPath, server: spec.name, detail: error.message)
        pid = nil
        startedAt = nil
        runTask = nil
        healthTask?.cancel()
        healthTask = nil
        await registryUpdate(id: id) { entry in
            entry.phase = .failed
            entry.pid = nil
            entry.spawnError = error
            entry.startedAt = nil
        }
        settleSpawnWaiters()
    }

    private func recordOutcome(_ outcome: ProcessOutcome, id: String) async {
        runTask = nil
        healthTask?.cancel()
        healthTask = nil
        switch outcome {
        case .spawnFailed(let error):
            await recordSpawnFailure(error, id: id)
            return
        case .exited(let code):
            lastExit = LastExit(at: Date(), code: code, signal: nil)
        case .signaled(let signal):
            lastExit = LastExit(at: Date(), code: nil, signal: signal)
        }
        if let out = outTailer { await out.stop() }
        if let err = errTailer { await err.stop() }
        outTailer = nil
        errTailer = nil
        pid = nil
        startedAt = nil
        observedPort = nil
        phase = stopRequested ? .stopped : .crashed
        stopRequested = false
        let finalPhase = phase
        let exit = lastExit
        let cause = exit?.code.map { "code=\($0)" } ?? exit?.signal.map { "signal=\($0)" } ?? "unknown"
        await logStore.append(stream: .sys, text: "exited \(cause)")
        await events?.post(
            kind: finalPhase == .stopped ? .stopped : .crashed,
            project: projectPath, server: spec.name, detail: cause)
        await registryUpdate(id: id) { entry in
            entry.lastExit = exit
            entry.phase = finalPhase
            entry.pid = nil
            entry.startedAt = nil
        }
        settleSpawnWaiters()
    }

    /** State persistence failures (full disk, permissions) must not kill the
        supervisor, but they must not vanish either: crash forensics silently
        missing is the suppression the repo rules forbid. */
    private func registryUpdate(id: String, _ mutate: @escaping @Sendable (inout PersistedServerState) -> Void) async {
        do {
            try await registry.updateState(serverID: id, mutate)
        } catch {
            FileHandle.standardError.write(
                Data("devctld: state persistence failed for \(id): \(error)\n".utf8))
        }
    }

    private func settleSpawnWaiters() {
        let waiters = spawnWaiters
        spawnWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static func specHash(_ spec: ServerSpec) -> String {
        guard let data = try? JSONCoding.encoder().encode(spec) else { return "" }
        return DevCtlPaths.hash8(String(decoding: data, as: UTF8.self))
    }

    private func specStaleFlag() -> Bool? {
        guard pid != nil, let running = runningSpecHash else { return nil }
        return running == Self.specHash(spec) ? nil : true
    }

    /** Last structured lines (out/err/sys), for crash/failure forensics. */
    private func spoolTail(lines: Int = 40) -> [String]? {
        let records = LogQuery.run(
            current: paths.structuredLogFile(project: projectPath, server: spec.name),
            options: LogQueryOptions(streams: [.err, .out, .sys], tail: lines))
        return records.isEmpty ? nil : records.map { "\($0.stream.rawValue): \($0.text)" }
    }

    private func waitForRunTaskCompletion() async {
        if let task = runTask { await task.value }
    }

    /** Blocks until the in-flight start has either produced a pid or gone
        terminal; the phase itself stays `starting` until first-healthy. */
    private func waitForSpawnSettled() async {
        guard phase == .starting, pid == nil else { return }
        await withCheckedContinuation { continuation in
            if phase != .starting || pid != nil {
                continuation.resume()
            } else {
                spawnWaiters.append(continuation)
            }
        }
    }
}
