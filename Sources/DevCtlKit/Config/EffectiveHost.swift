import Foundation

/** Why a server's effective host differs from the one its config declares.
    Append-only: the CLI switches exhaustively over this so a new case has to be
    given a sentence a reader can act on. */
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

/** One home for the host decision the spawn path makes, so `config check` can
    answer it before a server starts without reimplementing the rule. Pure: the
    caller computes `worktreeHost` (CheckoutIdentity shells out to git), which
    keeps this testable with no repository on disk. */
public enum EffectiveHostResolver {
    /** The project-level answer. A linked worktree swaps the whole project's
        host unless a server opts out below. */
    public static func project(
        declaredHost: String, worktreeHost: String?
    ) -> EffectiveHost {
        guard let worktreeHost else {
            return EffectiveHost(declared: declaredHost, effective: declaredHost)
        }
        return EffectiveHost(
            declared: declaredHost, effective: worktreeHost, reason: .linkedWorktree)
    }

    /** The per-server answer. The rule matches `prepareSpawn`: an overlay host
        wins outright, an explicit per-server host that is not simply the
        project's own host keeps its subdomain, and everything else follows the
        project. `specHost` is the post-validation host, which is already
        `entry.host ?? projectHost`, so equality with a project-shaped host is
        what distinguishes "declared nothing" from "declared an override". */
    public static func server(
        defaultSlugHost: String, overlayHost: String?, project: EffectiveHost, server: String,
        specHost: String?
    ) -> EffectiveHost {
        let declared = specHost ?? project.declared
        if let overlayHost {
            return EffectiveHost(
                declared: declared, effective: overlayHost,
                reason: overlayHost == declared ? nil : .localOverlay, server: server)
        }
        let followsProject =
            specHost == nil || specHost == project.declared || specHost == defaultSlugHost
        guard followsProject else {
            return EffectiveHost(
                declared: declared, effective: declared,
                reason: project.differs ? .serverOverride : nil, server: server)
        }
        return EffectiveHost(
            declared: declared, effective: project.effective, reason: project.reason,
            server: server)
    }
}
