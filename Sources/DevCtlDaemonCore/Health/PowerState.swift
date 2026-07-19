import Foundation

/** System sleep awareness shared by every health monitor. Probes pause during
    sleep, and failures inside the wake grace window are ignored so lid-open does
    not flap every server unhealthy while they shake themselves awake. */
public actor PowerState {
    public static let shared = PowerState()

    private var asleep = false
    private var wakeGraceUntil: ContinuousClock.Instant?

    public init() {}

    public func recordSleep() {
        asleep = true
    }

    public func recordWake(graceSeconds: Double = 10) {
        asleep = false
        wakeGraceUntil = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
    }

    /** How the health loop should treat this moment. */
    public func probePolicy() -> ProbePolicy {
        if asleep { return .skip }
        if let until = wakeGraceUntil {
            if ContinuousClock.now < until { return .ignoreFailures }
            wakeGraceUntil = nil
        }
        return .normal
    }

    public enum ProbePolicy: Sendable {
        case ignoreFailures
        case normal
        case skip
    }
}
