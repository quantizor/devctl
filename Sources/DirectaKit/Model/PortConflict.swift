import Foundation

/** Structured port-conflict signal agents branch on without parsing English.
    Present on status when a conflict was handled (rebound), is latent (held while
    stopped), or killed the run (drift). */
public struct PortConflict: Codable, Equatable, Sendable {
    public var declaredPort: Int
    public var effectivePort: Int?
    /** `server@project` for a managed holder, or a short unmanaged label. */
    public var holder: String?
    public var message: String
    public var state: PortConflictState

    public init(
        declaredPort: Int,
        effectivePort: Int? = nil,
        holder: String? = nil,
        message: String,
        state: PortConflictState
    ) {
        self.declaredPort = declaredPort
        self.effectivePort = effectivePort
        self.holder = holder
        self.message = message
        self.state = state
    }
}

public enum PortConflictState: String, Codable, Sendable {
    /** Sibling held the committed port; this run rebound and is serving elsewhere. */
    case rebound
    /** Declared/effective port is held and this server is not up yet (or ensure refused). */
    case held
    /** Child listened on a different port than effectivePort (Vite silent bump). */
    case drift
    /** The healthcheck passed but only processes outside this server's tree hold
        the port. Two cases share this state and they are not equally certain.
        When the owning pid belongs to another server this daemon supervises,
        theft is proven and the server fails: a green health signal that came
        from a stranger is worse than a red one. When the owner cannot be
        attributed, it may well be this server's own container or daemonized
        helper, so the conflict is recorded and the server keeps running. Read
        `message` to tell them apart; only the proven case ends in `failed`. */
    case foreign
    /** This server owns a listener on the port and so does a process outside its
        tree. Both stacks are bound (a v4-only listener beside a v6 wildcard, for
        instance), so which one answers a probe is not decided by directa. */
    case shared
}
