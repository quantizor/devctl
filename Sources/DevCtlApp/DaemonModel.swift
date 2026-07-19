import DevCtlKit
import Foundation
import Observation
import UserNotifications

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
            let request = UNNotificationRequest(
                identifier: "devctl-\(event.server)-\(event.at.timeIntervalSince1970)",
                content: content,
                trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
