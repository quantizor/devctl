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
    var projects: [ProjectGroup] = []

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
            await surfaceCrashNotifications(client: client)
        } catch {
            daemonReachable = false
            projects = []
        }
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
