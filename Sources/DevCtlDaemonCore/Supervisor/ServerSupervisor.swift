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
    /** Committed port before override/rebind; status.declaredPort. */
    private var declaredPort: Int?
    /** Error-stream tally for the current process, captured when the phase turns
        terminal or unhealthy rather than recomputed per status call. Cleared at
        spawn so a crash loop reports this incarnation, bracketed to the run's
        start, and persisted so it survives a daemon restart. */
    private var errorSummary: ErrorSummary?
    private var everHealthy = false
    /** What this run binds after override/rebind/materialization. */
    private var effectivePort: Int?
    private var healthTask: Task<Void, Never>?
    private var lastExit: LastExit?
    private var lastHealthAt: Date?
    private var lastDescendantSnapshot: [ProcessIdentity] = []
    private let launcher: any ProcessLauncher
    /** Resolved named secondaries for this run (status.ports). */
    private var namedPorts: [String: Int]?
    private var observedPort: Int?
    private let paths: DevCtlPaths
    private var phase: ServerPhase = .stopped
    private var pid: pid_t?
    private var portClaim: PortClaim?
    private var portConflict: PortConflict?
    private let prober: any HealthProber
    /** Captured when the phase turns terminal, not recomputed per status call:
        the log stops growing once the process is gone, so one read at the
        transition is both cheaper and a truer snapshot of the failure. */
    private var recentLogTail: [String]?
    private let registry: Registry
    private var runningSpecHash: String?
    private var runTask: Task<Void, Never>?
    private var spawnError: SpawnError?
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []
    private var spec: ServerSpec
    private var startedAt: Date?
    private var stopRequested = false
    /** Carries the stop()'s intent into recordOutcome: deliberate clears the
        resume-on-boot flag, a launchd drain keeps it. */
    private var stopWasDeliberate = true
    /** Durable why evidence across ensure truncate / daemon rehydrate. */
    private var terminalEvidence: [String]?

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
        /** Match Registry's normalized state keys (`/var` vs `/private/var`). */
        let project = canonicalProjectPath(projectPath)
        self.logStore = LogStore(currentURL: paths.structuredLogFile(project: project, server: spec.name))
        self.paths = paths
        self.prober = prober
        self.projectPath = project
        self.registry = registry
        self.spec = spec
        let id = serverID(project: project, name: spec.name)
        if let persisted = AtomicFile.loadDefensively(StateFile.self, from: paths.stateFile)?
            .servers[id] {
            self.errorSummary = persisted.errorSummary
            self.lastExit = persisted.lastExit
            self.spawnError = persisted.spawnError
            self.terminalEvidence = persisted.terminalEvidence
            if persisted.phase == .crashed || persisted.phase == .failed {
                self.phase = persisted.phase
            }
        }
    }

    public func updateSpec(_ newSpec: ServerSpec) {
        spec = newSpec
    }

    /** Port metadata for status/agents. Call after materializing the spawn spec. */
    public func setPortMeta(
        claim: PortClaim? = nil,
        declaredPort: Int?, effectivePort: Int?, portConflict: PortConflict? = nil
    ) {
        self.declaredPort = declaredPort
        self.effectivePort = effectivePort
        self.portClaim = claim
        self.namedPorts = claim.flatMap { $0.named.isEmpty ? nil : $0.named }
        self.portConflict = portConflict
    }

    public func clearBoundPortMeta() {
        portConflict = nil
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
        errorSummary = nil
        terminalEvidence = nil
        everHealthy = false
        observedPort = nil
        recentLogTail = nil
        lastDescendantSnapshot = []
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
        snapshotted before the first signal since orphans reparent to launchd.
        `deliberate` is true only for a user-invoked stop (devctl stop/down): it
        clears the resume-on-boot intent. A launchd drain passes false so the
        machine coming back up restores what was running. */
    public func stop(graceSeconds: Double = 7, deliberate: Bool = true) async -> ServerStatus {
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
        stopWasDeliberate = deliberate
        phase = .stopping
        /** Capture before any signal: after the grace window the pid number may
            name a different process, and SIGKILL must not follow a recycled id. */
        let rootIdentity = ProcessTree.identity(of: target)
        let snapshotResult = ProcessTree.descendants(of: target)
        if case .failed(let code) = snapshotResult {
            DevCtlLog.supervisor.error(
                "descendant sweep failed before SIGTERM (errno \(code)); group-only teardown")
        }
        let snapshot = snapshotResult.identities
        ProcessTree.signalTree(
            descendants: snapshot, rootPid: target, signal: SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if runTask == nil { break }
            if kill(target, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        /** Escalate: the pre-signal snapshot plus a fresh sweep (new children may
            have appeared during the grace window while the parent lived). */
        let fresh = ProcessTree.descendants(of: target)
        if case .failed(let code) = fresh {
            DevCtlLog.supervisor.error(
                "descendant sweep failed before SIGKILL (errno \(code)); using pre-signal snapshot")
        }
        var byPid: [pid_t: ProcessIdentity] = [:]
        for identity in snapshot + fresh.identities {
            byPid[identity.pid] = identity
        }
        let escalation = Array(byPid.values)
        if let rootIdentity,
            ProcessTree.shouldSignal(
                snapshotted: rootIdentity, live: ProcessTree.identity(of: target))
        {
            ProcessTree.signalTree(
                descendants: escalation, revalidate: true, rootIdentity: rootIdentity,
                rootPid: target, signal: SIGKILL)
        } else {
            ProcessTree.escalateIndividuals(escalation)
        }
        await waitForRunTaskCompletion()
        return status()
    }

    public func status() -> ServerStatus {
        let check = EffectiveHealthcheck.resolve(spec: spec)
        let terminal = phase == .crashed || phase == .failed
        /** The tail is captured once at the transition and served from memory. A
            server rehydrated as crashed after a daemon restart has none in memory
            (only errorSummary is persisted), so fall back to a live read there,
            which matches the pre-capture behavior for that narrow case. */
        let tail = terminal ? (recentLogTail ?? spoolTail()) : nil
        let evidence = terminal ? (terminalEvidence ?? tail) : nil
        return ServerStatus(
            declaredPort: declaredPort ?? spec.port,
            effectivePort: effectivePort ?? spec.port,
            errorSummary: errorSummary,
            heads: spec.heads,
            healthcheck: check.kind,
            icon: spec.icon,
            lastExit: lastExit,
            lastHealthAt: lastHealthAt,
            locks: spec.locks,
            logPath: paths.structuredLogFile(project: projectPath, server: spec.name).path,
            observedPort: observedPort,
            phase: phase,
            pid: pid.map(Int.init),
            portConflict: portConflict,
            ports: namedPorts,
            project: projectPath,
            recentLogTail: tail,
            server: spec.name,
            spawnError: spawnError,
            specStale: specStaleFlag(),
            terminalEvidence: evidence,
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
        if pid != nil {
            refreshDescendantSnapshot()
        }
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
                    DevCtlLog.supervisor.info("healthy \(spec.name)@\(projectPath)")
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
                /** The process is still writing, so snapshot the err tally at the
                    moment it degrades; a later recovery to running clears nothing,
                    so the count reflects the most recent unhealthy episode. */
                errorSummary = captureErrorSummary(since: startedAt)
                postHealthEvent(.unhealthy)
            }
        }
    }

    /** Post-healthy listen scan: dev servers auto-increment ports on conflict
        (Vite, Next), so the port actually listening is surfaced separately from
        the declared one. */
    private func scanObservedPort() {
        guard let rootPid = pid else { return }
        let expected = effectivePort ?? spec.port
        Task { [weak self] in
            let pids = [rootPid] + ProcessTree.descendants(of: rootPid).pids
            let ports = PortGuard.listeningPorts(pids: pids)
            await self?.recordObservedPort(ports: ports)
            guard let expected else { return }
            let owners = PortGuard.listenerPids(port: expected)
            await self?.recordPortOwnership(
                expected: expected, owners: owners, ours: pids.map(Int.init))
        }
    }

    /** The managed server whose recorded pid holds one of these listeners, if
        any. This is what separates "another devctl server took the port" from
        "the listener is simply not my child", which look identical from lsof
        alone. Returns the server name and its project separately: the internal
        id is `<project>::<name>`, which is not a string to show a reader. */
    private func managedOwner(among foreign: [Int]) async -> (name: String, project: String)? {
        let myID = serverID(project: projectPath, name: spec.name)
        let candidates = Set(foreign)
        for (id, entry) in await registry.allPersistedState() where id != myID {
            guard let pid = entry.pid, candidates.contains(pid) else { continue }
            /** A recorded pid is not an identity: macOS recycles pid numbers, so
                a stale row left by a killed daemon can name a pid that now
                belongs to something else entirely. Accusing on the number alone
                would blame an innocent server and take this one down with it.
                The recorded server's process must have started no later than the
                moment devctl recorded it starting; a recycled pid was born long
                after. One second of slack covers the spawn-to-record gap. */
            guard let startedAt = entry.startedAt,
                let identity = ProcessTree.identity(of: pid_t(pid))
            else { continue }
            let processStart = Date(timeIntervalSince1970: TimeInterval(identity.startSeconds))
            guard processStart <= startedAt.addingTimeInterval(1) else { continue }
            /** Split from the back: the project is an absolute path and the name
                never contains the separator. */
            guard let separator = id.range(of: "::", options: .backwards) else { continue }
            return (
                name: String(id[separator.upperBound...]),
                project: String(id[id.startIndex..<separator.lowerBound])
            )
        }
        return nil
    }

    /** A passing healthcheck proves something answered, never that this server
        answered. When every listener on the expected port sits outside this
        server's process tree, something else is serving on it.

        Two rules keep this from firing on healthy setups:

        Positive identification only. An empty listener list means lsof told us
        nothing, and lsof can be missing, restricted, or slow; treating silence
        as proof would fail healthy servers whenever the instrument is
        unavailable. Absence of evidence ends the check.

        Failing needs a named managed thief. A listener outside the process tree
        is not by itself a fault: a container-backed server (docker compose) or
        anything that daemonizes has its socket held by a process devctl never
        parented, and killing those runs would be wrong. Only when the owning pid
        belongs to another server this daemon supervises is theft proven, and
        only then does the phase change. Everything else is annotated so a reader
        can see the ambiguity without the server being taken down for it. */
    private func recordPortOwnership(expected: Int, owners: [Int], ours: [Int]) async {
        guard phase == .running || phase == .starting else { return }
        guard portConflict == nil else { return }
        guard !owners.isEmpty else { return }
        let mine = Set(ours)
        let foreign = owners.filter { !mine.contains($0) }
        guard !foreign.isEmpty else { return }
        let described = foreign
            .map { "pid \($0) (\(PortGuard.commandForPid($0)))" }
            .joined(separator: ", ")
        let thief = await managedOwner(among: foreign)
        /** We hold a listener too, so the server is serving; the port is just
            not exclusively ours and a probe may reach either side. */
        if owners.contains(where: { mine.contains($0) }) {
            portConflict = PortConflict(
                declaredPort: declaredPort ?? expected,
                effectivePort: expected,
                holder: described,
                message:
                    "port \(expected) is held by this server and also by \(described); a health probe may reach either one",
                state: .shared)
            DevCtlLog.supervisor.error(
                "port-shared \(spec.name)@\(projectPath) port \(expected) with \(described)")
            return
        }
        guard let thief else {
            /** Outside the tree but unattributable: could be this server's own
                container or daemonized helper. Say so, change nothing. */
            portConflict = PortConflict(
                declaredPort: declaredPort ?? expected,
                effectivePort: expected,
                holder: described,
                message:
                    "port \(expected) is held by \(described), which is outside this server's process tree; that is expected for a container-backed or daemonizing server, but a health probe cannot tell that apart from another process answering for it",
                state: .foreign)
            DevCtlLog.supervisor.info(
                "port-foreign-unattributed \(spec.name)@\(projectPath) port \(expected) owned by \(described)")
            return
        }
        portConflict = PortConflict(
            declaredPort: declaredPort ?? expected,
            effectivePort: expected,
            holder: "\(thief.name)@\(thief.project)",
            message:
                "healthcheck passed but managed server '\(thief.name)' in \(thief.project) owns port \(expected), not this server; run: devctl stop \(thief.name) --project \(thief.project)",
            state: .foreign)
        phase = .failed
        spawnError = SpawnError(
            message: "port \(expected) is owned by managed server '\(thief.name)' in \(thief.project), so the healthcheck was answered by another devctl server")
        errorSummary = captureErrorSummary(since: startedAt)
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
        healthTask?.cancel()
        DevCtlLog.supervisor.error(
            "port-foreign \(spec.name)@\(projectPath) port \(expected) owned by \(thief.name)@\(thief.project)")
        await events?.post(
            kind: .failed, project: projectPath, server: spec.name,
            detail: "port \(expected) owned by managed server \(thief)")
        let id = serverID(project: projectPath, name: spec.name)
        let summary = errorSummary
        let err = spawnError
        let evidence = terminalEvidence
        await registryUpdate(id: id) { entry in
            entry.errorSummary = summary
            entry.phase = .failed
            entry.spawnError = err
            entry.terminalEvidence = evidence
        }
    }

    private func recordObservedPort(ports: [Int]) async {
        guard !ports.isEmpty else { return }
        let expected = effectivePort ?? spec.port
        let claimPorts = Set(portClaim?.allPorts ?? expected.map { [$0] } ?? [])
        if let expected, ports.contains(expected) {
            observedPort = expected
        } else if let claimed = ports.first(where: { claimPorts.contains($0) }) {
            observedPort = claimed
        } else {
            observedPort = ports.first
        }
        /** Strict bind: primary must match. Listeners on claimed secondaries are
            expected for composites; anything outside the claim is drift. */
        guard let expected, let observed = observedPort,
            phase == .running || phase == .starting
        else { return }
        if observed == expected || claimPorts.contains(observed) {
            if observed == expected { return }
            /** Secondary claimed port observed without primary: still require primary. */
            if ports.contains(expected) { return }
        }
        guard observed != expected else { return }
        portConflict = PortConflict(
            declaredPort: declaredPort ?? expected,
            effectivePort: expected,
            message:
                "server listened on \(observed) instead of \(expected); add {port} to the command, set portEnv, or use --port / devctl.local.json",
            state: .drift)
        phase = .failed
        spawnError = SpawnError(message: "port drift: expected \(expected), observed \(observed)")
        errorSummary = captureErrorSummary(since: startedAt)
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
        healthTask?.cancel()
        DevCtlLog.supervisor.error(
            "port-drift \(spec.name)@\(projectPath) expected \(expected) observed \(observed)")
        await events?.post(
            kind: .failed, project: projectPath, server: spec.name,
            detail: "port drift \(expected)->\(observed)")
        let id = serverID(project: projectPath, name: spec.name)
        let summary = errorSummary
        let err = spawnError
        let evidence = terminalEvidence
        await registryUpdate(id: id) { entry in
            entry.errorSummary = summary
            entry.phase = .failed
            entry.spawnError = err
            entry.terminalEvidence = evidence
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
        refreshDescendantSnapshot()
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
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            await self?.refreshDescendantSnapshot()
        }
        await registryUpdate(id: id) { entry in
            entry.lastExit = nil
            entry.phase = .starting
            entry.pid = Int(childPid)
            entry.resumeOnBoot = true
            entry.spawnError = nil
            entry.startedAt = spawnedAt
        }
        settleSpawnWaiters()
    }

    private func refreshDescendantSnapshot() {
        guard let pid else { return }
        lastDescendantSnapshot = ProcessTree.descendants(of: pid).identities
    }

    /** Snapshot the err-stream tally for the run that just started at
        `windowStart`. Reads only from that point forward, so a crash loop reports
        the current incarnation rather than the whole log history. */
    private func captureErrorSummary(since windowStart: Date?) -> ErrorSummary? {
        LogQuery.summarize(
            current: paths.structuredLogFile(project: projectPath, server: spec.name),
            streams: [.err], since: windowStart)
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
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
        let evidence = terminalEvidence
        await registryUpdate(id: id) { entry in
            entry.phase = .failed
            entry.pid = nil
            entry.spawnError = error
            entry.startedAt = nil
            entry.terminalEvidence = evidence
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
        let windowStart = startedAt
        if let out = outTailer { await out.stop() }
        if let err = errTailer { await err.stop() }
        outTailer = nil
        errTailer = nil
        /** After the final drain, so the lines that explain the exit are in the
            log before the snapshots are taken. */
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
        errorSummary = captureErrorSummary(since: windowStart)
        if !stopRequested, let rootPid = pid {
            ProcessTree.signalTree(
                descendants: lastDescendantSnapshot, rootPid: rootPid, signal: SIGTERM)
        }
        lastDescendantSnapshot = []
        pid = nil
        startedAt = nil
        observedPort = nil
        phase = stopRequested ? .stopped : .crashed
        stopRequested = false
        let finalPhase = phase
        let exit = lastExit
        /** A deliberate stop retires the boot intent; a drain (or a crash) keeps
            whatever was recorded at start so the next boot restores it. */
        let retireIntent = finalPhase == .stopped && stopWasDeliberate
        let cause = exit?.code.map { "code=\($0)" } ?? exit?.signal.map { "signal=\($0)" } ?? "unknown"
        await logStore.append(stream: .sys, text: "exited \(cause)")
        await events?.post(
            kind: finalPhase == .stopped ? .stopped : .crashed,
            project: projectPath, server: spec.name, detail: cause)
        let errors = errorSummary
        let evidence = finalPhase == .stopped ? nil : terminalEvidence
        if finalPhase == .stopped { terminalEvidence = nil }
        await registryUpdate(id: id) { entry in
            entry.errorSummary = errors
            entry.lastExit = exit
            entry.phase = finalPhase
            entry.pid = nil
            if retireIntent { entry.resumeOnBoot = nil }
            entry.startedAt = nil
            entry.terminalEvidence = evidence
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
        return records.isEmpty ? nil : records.map(\.contextLine)
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
