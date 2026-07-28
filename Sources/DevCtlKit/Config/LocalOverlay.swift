import Foundation

/** Gitignored per-checkout overlay (`devctl.local.json`): a partial server map
    merged onto committed specs so a worktree can override port/command/env/url
    without dirtying tracked `devservers.json`. */
public struct LocalOverlayFile: Codable, Equatable, Sendable {
    public var servers: [String: LocalOverlayServer]?

    public init(servers: [String: LocalOverlayServer]? = nil) {
        self.servers = servers
    }
}

public struct LocalOverlayServer: Codable, Equatable, Sendable {
    public var command: [String]?
    public var cwd: String?
    public var env: [String: String]?
    public var heads: [String: String]?
    public var healthcheck: HealthCheckSpec?
    public var host: String?
    public var port: Int?
    public var portEnv: String?
    public var ports: [String: SecondaryPort]?
    public var portSpan: Int?
    public var shell: Bool?
    public var url: String?

    public init(
        command: [String]? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        heads: [String: String]? = nil,
        healthcheck: HealthCheckSpec? = nil,
        host: String? = nil,
        port: Int? = nil,
        portEnv: String? = nil,
        ports: [String: SecondaryPort]? = nil,
        portSpan: Int? = nil,
        shell: Bool? = nil,
        url: String? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.env = env
        self.heads = heads
        self.healthcheck = healthcheck
        self.host = host
        self.port = port
        self.portEnv = portEnv
        self.ports = ports
        self.portSpan = portSpan
        self.shell = shell
        self.url = url
    }
}

public enum LocalOverlay {
    public static func overlayURL(project: String) -> URL {
        URL(fileURLWithPath: project).appending(path: "devctl.local.json")
    }

    public static func load(project: String) -> LocalOverlayFile? {
        let url = overlayURL(project: project)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode(LocalOverlayFile.self, from: data)
    }

    /** Merge overlay fields onto a validated spec. Overlay wins per field. */
    public static func apply(spec: ServerSpec, overlay: LocalOverlayServer?, project: String) -> ServerSpec {
        guard let overlay else { return spec }
        var next = spec
        if let command = overlay.command { next.command = command }
        if let cwd = overlay.cwd { next.cwd = cwd }
        if let env = overlay.env {
            var merged = next.env ?? [:]
            for (key, value) in env { merged[key] = value }
            next.env = merged
        }
        if let heads = overlay.heads { next.heads = heads }
        if let healthcheck = overlay.healthcheck { next.healthcheck = healthcheck }
        if let host = overlay.host { next.host = host }
        if let port = overlay.port { next.port = port }
        if let portEnv = overlay.portEnv { next.portEnv = portEnv }
        if let ports = overlay.ports { next.ports = ports }
        if let portSpan = overlay.portSpan { next.portSpan = portSpan }
        if let shell = overlay.shell { next.shell = shell }
        if let url = overlay.url {
            next.url = url
        } else if overlay.port != nil || overlay.host != nil {
            let host = next.host ?? ProjectConfigLoader.defaultSlug(project: project) + ".localhost"
            if let port = next.port {
                next.url = "http://\(host):\(port)/"
            }
        }
        return next
    }
}
