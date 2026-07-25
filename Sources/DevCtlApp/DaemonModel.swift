import DevCtlKit
import Foundation
import Observation
import UserNotifications

/** How the popover orders its project groups. Persisted in UserDefaults so the
    choice survives relaunches. */
enum ProjectSortOrder: String, CaseIterable, Identifiable {
    case alphabetical
    case frequentlyUsed
    case recentlyUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: "A to Z"
        case .frequentlyUsed: "Frequently used"
        case .recentlyUsed: "Recently used"
        }
    }
}

/** A 7-day access journal: every interaction that opens or controls a server
    appends a timestamped entry for that project. Powers both "frequently used"
    (count-weighted, most first) and "recently used" (latest first) ordering.
    Entries older than the window are pruned on write so the store stays small. */
@Observable
final class ProjectAccessLog {
    static let shared = ProjectAccessLog()

    /** Accesses within this window count toward "frequently used". */
    static let windowSeconds: TimeInterval = 7 * 24 * 3600

    private static let defaultsKey = "project access log"
    private static let maxEntries = 400

    /** project path -> epoch seconds of each recorded access, newest last. */
    private var log: [String: [TimeInterval]] = [:]

    init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [TimeInterval]] ?? [:]
        log = raw
        prune()
    }

    /** Record an interaction for the project that owns `projectPath`. */
    func record(projectPath: String) {
        let now = Date().timeIntervalSince1970
        log[projectPath, default: []].append(now)
        prune()
        persist()
    }

    /** Most-accessed-first within the rolling window; ties break by recency. */
    func frequencyScore(projectPath: String) -> Int {
        let cutoff = Date().timeIntervalSince1970 - Self.windowSeconds
        return (log[projectPath] ?? []).count { $0 >= cutoff }
    }

    func lastAccess(projectPath: String) -> TimeInterval {
        log[projectPath]?.last ?? 0
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - Self.windowSeconds
        for (path, stamps) in log {
            var kept = stamps.filter { $0 >= cutoff }
            if kept.count > Self.maxEntries { kept = Array(kept.suffix(Self.maxEntries)) }
            if kept.isEmpty { log.removeValue(forKey: path) } else { log[path] = kept }
        }
    }

    private func persist() {
        UserDefaults.standard.set(log, forKey: Self.defaultsKey)
    }
}

/** The app's single source of truth: polls the daemon over the local socket
    (2s; polling is restart-safe and deletes the reconnect problem a push
    subscription would carry), groups servers by project, derives the ambient
    icon state, and posts crash notifications from the event feed. */
@Observable
final class DaemonModel {
    /** Bumped on system theme change so the baked menu bar label re-renders. */
    var appearanceTick = 0
    var daemonReachable = false
    /** Last failed recovery, surfaced in the popover so a dead daemon is never
        a dead end. */
    var daemonRecoveryError: String?
    /** True while a bootstrap/kickstart is in flight, so the row can say so and
        the poll does not stack attempts. */
    var daemonRecovering = false
    /** macOS registered the background agent but is waiting for the user to
        switch it on. Nothing the app can retry, so the popover asks for the
        approval instead of looping. */
    var daemonNeedsApproval = false
    /** `devctl daemon stop` wrote the deliberate-stop marker: the app offers
        Start instead of resurrecting the daemon behind the user's back. */
    var daemonStoppedOnPurpose = false
    var projects: [ProjectGroup] = []

    private var lastRecoveryAttempt: Date?

    struct ProjectGroup: Identifiable {
        var id: String { path }
        let name: String
        let path: String
        let servers: [ServerStatus]
    }

    /** Worst phase across every server, for the menu bar glyph. */
    enum AmbientState {
        case attention
        case busy
        case quiet

        init(servers: [ServerStatus]) {
            if servers.contains(where: { $0.phase == .crashed || $0.phase == .failed || $0.phase == .unhealthy }) {
                self = .attention
            } else if servers.contains(where: { $0.phase == .starting || $0.phase == .stopping }) {
                self = .busy
            } else {
                self = .quiet
            }
        }
    }

    var ambient: AmbientState {
        AmbientState(servers: projects.flatMap(\.servers))
    }

    /** Presence counts for the collapsed menu bar label. */
    var attentionCount: Int {
        projects.flatMap(\.servers)
            .count { $0.phase == .crashed || $0.phase == .failed || $0.phase == .unhealthy }
    }

    var busyCount: Int {
        projects.flatMap(\.servers).count { $0.phase == .starting || $0.phase == .stopping }
    }

    var runningCount: Int {
        projects.flatMap(\.servers).count { $0.phase == .running }
    }

    /** Order projects per the user's sort choice. Usage orders are computed
        from the shared access log; alphabetical is stable by name. */
    func sortedProjects(_ order: ProjectSortOrder) -> [ProjectGroup] {
        switch order {
        case .alphabetical:
            return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .frequentlyUsed:
            let log = ProjectAccessLog.shared
            return projects.sorted {
                let a = log.frequencyScore(projectPath: $0.path)
                let b = log.frequencyScore(projectPath: $1.path)
                if a != b { return a > b }
                let ra = log.lastAccess(projectPath: $0.path)
                let rb = log.lastAccess(projectPath: $1.path)
                if ra != rb { return ra > rb }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .recentlyUsed:
            let log = ProjectAccessLog.shared
            return projects.sorted {
                let a = log.lastAccess(projectPath: $0.path)
                let b = log.lastAccess(projectPath: $1.path)
                if a != b { return a > b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private var lastEventCheck = Date()
    private var notificationsReady = false
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        requestNotificationPermission()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appearanceTick += 1
            }
        }
        /** Launch-time registration runs behind the same in-flight flag and
            cooldown as recovery. Left outside them, the 2s poll sees the socket
            still silent inside launchd's respawn throttle and fires a second
            unregister + register on top of the first. */
        Task { [weak self] in
            guard let self else { return }
            daemonRecovering = true
            await AgentService.ensureAtLaunchIfNeeded()
            lastRecoveryAttempt = Date()
            daemonRecovering = false
            await refresh()
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
        do {
            let all = try await client.request(
                .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self)
            daemonReachable = true
            let grouped = Dictionary(grouping: all.servers, by: \.project)
            projects = grouped.keys.sorted().map { path in
                ProjectGroup(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    servers: (grouped[path] ?? []).sorted { $0.server < $1.server })
            }
            SpotlightIndexer.sync(projects: projects)
            daemonRecoveryError = nil
            lastRecoveryAttempt = nil
            daemonStoppedOnPurpose = false
            await surfaceCrashNotifications(client: client)
        } catch {
            daemonReachable = false
            projects = []
            daemonStoppedOnPurpose = LaunchdAdmin.deliberatelyStopped()
            await recoverDaemonIfNeeded()
        }
    }

    /** Bring the daemon back on its own after a crash or a failed relaunch.
        Skipped when the user stopped it on purpose (their intent wins) and
        rate-limited so a permanently broken install does not spin. */
    private func recoverDaemonIfNeeded() async {
        let decision = DaemonRecoveryPolicy.decide(
            reachable: daemonReachable,
            stoppedOnPurpose: daemonStoppedOnPurpose,
            recovering: daemonRecovering,
            lastAttempt: lastRecoveryAttempt)
        guard decision == .recover else { return }
        lastRecoveryAttempt = Date()
        daemonRecovering = true
        let recovered = await recoverAgent()
        daemonRecovering = false
        if recovered {
            daemonRecoveryError = nil
            await refresh()
        } else if daemonNeedsApproval {
            daemonRecoveryError = AgentService.Failure.needsApproval.localizedDescription
        } else {
            daemonRecoveryError = "could not start devctld automatically"
        }
    }

    /** Prefer SMAppService inside this app process; fall back to the legacy home
        LaunchAgent only when this bundle cannot host an agent. Falling back while
        approval is pending would write back the very `~/Library/LaunchAgents`
        job the migration removed, and Login Items would name it `devctld` again. */
    private func recoverAgent() async -> Bool {
        if AgentService.bundleHasAgentPlist {
            do {
                try await AgentService.ensureRunning()
                daemonNeedsApproval = false
                return true
            } catch AgentService.Failure.needsApproval {
                daemonNeedsApproval = true
                DevCtlLog.app.error("agent awaiting approval in Login Items")
                return false
            } catch {
                DevCtlLog.app.error("SMAppService recover failed: \(error.localizedDescription)")
                return false
            }
        }
        return await LaunchdAdmin.attemptBootstrap(
            extraDaemonCandidates: Self.bundledDaemonCandidates(), forceLegacy: true)
    }

    /** Explicit Start from the popover: clears a deliberate-stop marker, so it
        also works when auto recovery is intentionally standing down. */
    func startDaemon() {
        guard !daemonRecovering else { return }
        Task {
            daemonRecovering = true
            daemonRecoveryError = nil
            do {
                if AgentService.bundleHasAgentPlist {
                    try await AgentService.ensureRunning()
                } else {
                    try await LaunchdAdmin.startOrInstall(
                        extraDaemonCandidates: Self.bundledDaemonCandidates(),
                        forceLegacy: true)
                }
                daemonNeedsApproval = false
                daemonStoppedOnPurpose = false
            } catch AgentService.Failure.needsApproval {
                daemonNeedsApproval = true
                daemonRecoveryError = AgentService.Failure.needsApproval.localizedDescription
            } catch let error as WireError {
                daemonRecoveryError = error.message
            } catch {
                daemonRecoveryError = error.localizedDescription
            }
            daemonRecovering = false
            await refresh()
        }
    }

    /** The version-matched devctld inside this app bundle's Resources, which is
        the right install source when no LaunchAgent exists yet. */
    private static func bundledDaemonCandidates() -> [URL] {
        guard
            let url = Bundle.main.url(
                forResource: SetupPlanner.resourceDaemonName, withExtension: nil)
        else { return [] }
        return [url]
    }

    func startServer(_ server: ServerStatus) {
        ProjectAccessLog.shared.record(projectPath: server.project)
        Task {
            let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
            _ = try? await client.request(
                .serverEnsure,
                params: EnsureParams(name: server.server, project: server.project, timeoutSeconds: 60),
                expecting: EnsureResult.self)
            await refresh()
        }
    }

    func stopServer(_ server: ServerStatus) {
        ProjectAccessLog.shared.record(projectPath: server.project)
        Task {
            let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
            _ = try? await client.request(
                .serverStop,
                params: ServerTargetParams(name: server.server, project: server.project),
                expecting: ServerResult.self)
            await refresh()
        }
    }

    func restartServer(_ server: ServerStatus) {
        ProjectAccessLog.shared.record(projectPath: server.project)
        Task {
            let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
            _ = try? await client.request(
                .serverStop,
                params: ServerTargetParams(name: server.server, project: server.project),
                expecting: ServerResult.self)
            _ = try? await client.request(
                .serverEnsure,
                params: EnsureParams(name: server.server, project: server.project, timeoutSeconds: 60),
                expecting: EnsureResult.self)
            await refresh()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsReady = granted
            }
        }
    }

    /** Crash notifications ride the event feed so nothing is missed between
        polls; lastEventCheck advances to the newest seen event. */
    private func surfaceCrashNotifications(client: DaemonClient) async {
        guard notificationsReady else { return }
        guard
            let feed = try? await client.request(
                .eventsQuery,
                params: EventsQueryParams(since: lastEventCheck),
                expecting: EventsQueryResult.self)
        else { return }
        for event in feed.events where event.at > lastEventCheck {
            lastEventCheck = max(lastEventCheck, event.at)
            guard event.kind == .crashed || event.kind == .failed else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(event.server) \(event.kind.rawValue)"
            content.body = event.detail.map { "\($0) · \((event.project as NSString).lastPathComponent)" }
                ?? (event.project as NSString).lastPathComponent
            content.categoryIdentifier = AppDeepLinkDispatch.serverAlertCategory
            content.userInfo = [
                AppDeepLinkDispatch.userInfoProject: event.project,
                AppDeepLinkDispatch.userInfoServer: event.server,
            ]
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "devctl-\(event.server)-\(event.at.timeIntervalSince1970)",
                content: content,
                trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            DevCtlLog.app.info("notified \(event.kind.rawValue) \(event.server)")
        }
    }
}
