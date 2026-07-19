import AppKit
import CoreSpotlight
import DevCtlKit
import ServiceManagement
import SwiftUI

/** Handles Spotlight item activation: a background (LSUIElement) app receives
    it through the app delegate, not a scene view, since the popover's view tree
    may not exist when Spotlight launches us. */
final class SpotlightActivationDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
            let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let url = SpotlightIndexer.url(forIdentifier: identifier)
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

/** devctl.app: quiet instrument panel in the menu bar. The glyph reports
    aggregate health ambiently; the dropdown is per-project rows with tally-light
    dots; the dashboard window carries logs/timeline (its phase). Unsandboxed by
    necessity (unix socket), LSUIElement, no Dock icon. */
@main
struct DevCtlApp: App {
    @NSApplicationDelegateAdaptor(SpotlightActivationDelegate.self) private var spotlightDelegate
    @State private var model = DaemonModel()

    /** Polling starts at launch, not first popover open: the collapsed label's
        presence dots must be live from the first frame. */
    init() {
        let launched = DaemonModel()
        launched.start()
        _model = State(initialValue: launched)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            /** A real child View, not inline scene content: App.body scene
                closures do not participate in Observation tracking, so counts
                read here directly would never re-render the collapsed label. */
            PresenceLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("devctl", id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 860, height: 560)
    }
}

struct MenuContent: View {
    @State private var contentHeight: CGFloat = 0
    @Environment(\.openWindow) private var openWindow
    var model: DaemonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.daemonReachable {
                Label("devctld is not running", systemImage: "bolt.slash")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if model.projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No servers registered")
                    Text("devctl register --name web --cmd …")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                /** Autogrow: the popover takes exactly its content height up to
                    the cap, then scrolls, instead of sitting tight at a fixed
                    frame. The inner VStack's measured height drives the frame. */
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.projects) { project in
                            ProjectSection(model: model, project: project)
                        }
                    }
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { measured in
                        contentHeight = measured
                    }
                }
                .frame(height: min(max(contentHeight, 44), 560))
            }
            Divider()
            HStack {
                Button("Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)
                Spacer()
                LaunchAtLoginToggle()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }
}

struct ProjectSection: View {
    var model: DaemonModel
    let project: DaemonModel.ProjectGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(project.servers, id: \.server) { server in
                ServerRow(model: model, server: server)
            }
        }
    }
}

struct ServerRow: View {
    var model: DaemonModel
    let server: ServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TallyDot(phase: server.phase)
                /** Clicking the row opens the server's URL: the whole point of
                    the signature is a one-click browser origin. */
                Button {
                    if let url = server.url.flatMap(URL.init(string:)) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.server)
                            .fontWeight(.medium)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(server.url == nil)
                .help(server.url ?? "no URL configured")
                Spacer()
                controls
            }
            /** Multi-headed servers list their surfaces as nested compact rows,
                each a direct click-to-open; pinned heads float to the top. */
            if let heads = server.heads, !heads.isEmpty {
                let pins = HeadPins.shared
                let ordered = heads.sorted { a, b in
                    let aPinned = pins.isPinned(project: server.project, server: server.server, head: a.key)
                    let bPinned = pins.isPinned(project: server.project, server: server.server, head: b.key)
                    if aPinned != bPinned { return aPinned }
                    return a.key < b.key
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(ordered, id: \.key) { name, url in
                        HeadRow(
                            name: name,
                            pinned: pins.isPinned(project: server.project, server: server.server, head: name),
                            url: url
                        ) {
                            pins.toggle(project: server.project, server: server.server, head: name)
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let url = server.url, let parsed = URL(string: url), let host = parsed.host {
            let port = parsed.port.map { ":\($0)" } ?? ""
            return "\(host)\(port) · \(server.phase.rawValue)"
        }
        if let port = server.declaredPort {
            return "port \(port) · \(server.phase.rawValue)"
        }
        return server.phase.rawValue
    }

    @ViewBuilder private var controls: some View {
        switch server.phase {
        case .running, .unhealthy, .starting:
            Button {
                model.restartServer(server)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Restart")
            Button {
                model.stopServer(server)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop")
        case .stopped, .crashed, .failed, .stopping:
            Button {
                model.startServer(server)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Start")
            .disabled(server.phase == .stopping)
        }
    }
}

/** Collapsed presence: template rack glyph (adapts to the bar) plus colored
    dot+count pairs baked into an NSImage, because MenuBarExtra flattens live
    SwiftUI color to template monochrome; a rendered image keeps its color.
    Only nonzero groups appear, so all-quiet is just the rack. */
struct PresenceLabel: View {
    var model: DaemonModel

    var body: some View {
        /** One baked image for everything: MenuBarExtra labels render only a
            single image, so the rack and the colored dots share one
            ImageRenderer pass (appearanceTick re-bakes on theme change). */
        let _ = model.appearanceTick
        if let label = PresenceDots.image(
            attention: model.attentionCount,
            busy: model.busyCount,
            running: model.runningCount) {
            Image(nsImage: label)
        } else {
            Image(systemName: "server.rack")
        }
    }
}

/** Renders the colored dot+count pairs for the collapsed menu bar label, cached
    by count triple so the 2s poll does not re-render an unchanged image. */
enum PresenceDots {
    private struct Key: Hashable {
        let attention: Int
        let busy: Int
        let dark: Bool
        let running: Int
    }

    @MainActor private static var cache: [Key: NSImage] = [:]

    @MainActor static func image(attention: Int, busy: Int, running: Int) -> NSImage? {
        guard attention + busy + running > 0 else { return nil }
        /** No monochrome ink in the baked image: the menu bar's tint follows the
            wallpaper, not the system theme, so any fixed ink can vanish. The
            mid-tone dot colors read on every bar; the adaptive rack shows only
            in the all-quiet state (as a live template symbol, not baked). */
        let key = Key(attention: attention, busy: busy, dark: false, running: running)
        if let cached = cache[key] { return cached }
        let content = HStack(spacing: 5) {
            pair(count: running, color: Color(red: 0.28, green: 0.75, blue: 0.42))
            pair(count: busy, color: Color(red: 0.95, green: 0.72, blue: 0.2))
            pair(count: attention, color: Color(red: 0.92, green: 0.34, blue: 0.3))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let rendered = renderer.nsImage else { return nil }
        /** Color must survive: never a template image. */
        rendered.isTemplate = false
        if cache.count > 32 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    @ViewBuilder private static func pair(count: Int, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 2.5) {
                Circle()
                    .fill(color)
                    .frame(width: 6.5, height: 6.5)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
        }
    }
}

/** Pinned-head preference, persisted across launches (UserDefaults). Keys are
    `project::server::head` so pins survive renames of nothing they should not. */
@Observable
final class HeadPins {
    static let shared = HeadPins()

    private static let defaultsKey = "pinned heads"
    private var pinned: Set<String>

    init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isPinned(project: String, server: String, head: String) -> Bool {
        pinned.contains("\(project)::\(server)::\(head)")
    }

    func toggle(project: String, server: String, head: String) {
        let key = "\(project)::\(server)::\(head)"
        if pinned.contains(key) {
            pinned.remove(key)
        } else {
            pinned.insert(key)
        }
        UserDefaults.standard.set(pinned.sorted(), forKey: Self.defaultsKey)
    }
}

/** A nested head entry: compact, quiet, the whole line clickable; the pin
    toggle appears on hover and pinned rows keep a subtle filled pin. */
struct HeadRow: View {
    @State private var hovering = false
    let name: String
    let pinned: Bool
    let url: String
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let parsed = URL(string: url) {
                    NSWorkspace.shared.open(parsed)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(name)
                        .font(.caption)
                    Text(displayHost)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url)
            .accessibilityLabel(Text("Open \(name)"))
            if pinned || hovering {
                Button(action: onTogglePin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 8))
                        .foregroundStyle(pinned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help(pinned ? "Unpin" : "Pin to top")
                .accessibilityLabel(Text(pinned ? "Unpin \(name)" : "Pin \(name) to top"))
            }
        }
        .background(
            hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
    }

    private var displayHost: String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        return parsed.port.map { "\(host):\($0)" } ?? host
    }
}

/** The tally light: state as color, `starting` breathes. Never shouts. */
struct TallyDot: View {
    @State private var breathing = false
    let phase: ServerPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(phase == .starting ? (breathing ? 1.0 : 0.35) : 1.0)
            .animation(
                phase == .starting
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: breathing
            )
            .onAppear { breathing = true }
            .accessibilityLabel(Text(phase.rawValue))
    }

    private var color: Color {
        switch phase {
        case .running: .green
        case .starting, .stopping: .yellow
        case .unhealthy: .orange
        case .crashed, .failed: .red
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Login", isOn: $enabled)
            .toggleStyle(.checkbox)
            .font(.caption)
            .onChange(of: enabled) { _, wanted in
                do {
                    if wanted {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
            .help("Launch devctl.app at login")
    }
}


