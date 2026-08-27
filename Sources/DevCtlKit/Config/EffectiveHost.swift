import Foundation

/** Why a server's effective host differs from the one its config declares.
    Append-only: the CLI switches exhaustively over this so a new case has to be
    given a sentence a reader can act on. Only `localOverlay` is produced
    today; `linkedWorktree` and `serverOverride` stay decodable so payloads
    from older builds still parse, and `serverOverride` documents the shape a
    future project-level host override would produce. */
public enum EffectiveHostReason: String, Codable, Sendable {
    case linkedWorktree = "linked-worktree"
    case localOverlay = "local-overlay"
    case serverOverride = "server-override"
}

/** The host a spawn would actually use, next to the one the file declares.
    Mirrors `declaredPort` / `effectivePort` on ServerStatus, so the same
    question can be answered for a host before anything starts. */
public struct EffectiveHost: Codable, Equatable, Sendable {
    public var declared: String
    public var effective: String
    public var reason: EffectiveHostReason?
    /** Nil for the project-level answer. */
    public var server: String?

    public init(
        declared: String, effective: String, reason: EffectiveHostReason? = nil,
        server: String? = nil
    ) {
        self.declared = declared
        self.effective = effective
        self.reason = reason
        self.server = server
    }

    public var differs: Bool { declared != effective }
}

/** One home for the per-server host decision, so `config check` can answer it
    before a server starts without reimplementing the rule. A linked worktree
    is deliberately absent: the declared host is used unchanged there (the
    worktree name surfaces as a display value instead), so the only host
    difference left is a `devctl.local.json` overlay. Pure: nothing here
    touches the filesystem, which keeps this testable with no repository on
    disk. */
public enum EffectiveHostResolver {
    /** The per-server answer. The rule matches `prepareSpawn`: an overlay host
        wins outright, an explicit per-server host that is not simply the
        project's own host keeps its subdomain, and everything else follows the
        project. `specHost` is the post-validation host, which is already
        `entry.host ?? projectHost`, so equality with a project-shaped host is
        what distinguishes "declared nothing" from "declared an override". */
    public static func server(
        defaultSlugHost: String, declaredHost: String, overlayHost: String?, server: String,
        specHost: String?
    ) -> EffectiveHost {
        let declared = specHost ?? declaredHost
        if let overlayHost {
            return EffectiveHost(
                declared: declared, effective: overlayHost,
                reason: overlayHost == declared ? nil : .localOverlay, server: server)
        }
        let followsProject =
            specHost == nil || specHost == declaredHost || specHost == defaultSlugHost
        guard followsProject else {
            return EffectiveHost(declared: declared, effective: declared, server: server)
        }
        return EffectiveHost(declared: declared, effective: declaredHost, server: server)
    }
}
