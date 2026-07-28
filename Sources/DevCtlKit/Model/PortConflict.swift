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
}
