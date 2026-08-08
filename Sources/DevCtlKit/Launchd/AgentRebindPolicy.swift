import Foundation

/** Decide helpers for SMAppService helper upgrades after a DMG replace.

    Ad-hoc resigns change the helper CDHash. The first `register()` after replace
    often dies with Launch Constraint Violation. KeepAlive then asks smd to repair
    the LWCR in place; for ad-hoc (empty Team ID) that returns
    `Unable to update LWCR with smd: 22` and another 10s throttle. Waiting does
    not help. A second unregister+register submits a fresh job whose LWCR matches
    the on-disk helper. Developer ID builds are far less sensitive. */
public enum AgentRebindPolicy {
    /** Idle after launchd reports the agent gone, before replacing the helper
        or calling register again. Long enough for unload, not a BTM cure. */
    public static let settleSeconds: TimeInterval = 1

    /** How long to wait for the first post-replace spawn before forcing a
        fresh unregister+register (KeepAlive LWCR repair is a dead end). */
    public static let postReplaceHelloSeconds: TimeInterval = 1.5

    /** How long to wait for the spawn that FOLLOWS a re-register.

        An unregister+register restarts launchd's ThrottleInterval, which
        defaults to 10s, so the new job cannot spawn before then no matter how
        healthy it is. Waiting 10 put the deadline in a dead heat with the spawn
        and lost: on a real DMG upgrade the poll expired at 11.8s, the launch
        sequence gave up, and the daemon only arrived when a later escalation
        re-registered it half a minute after the app opened. This is the throttle
        plus room for the spawn itself, so the wait outlasts the thing it waits
        for. */
    public static let postReregisterHelloSeconds: TimeInterval = 16

    /** Whether launch should register the agent. A post-upgrade rebind marker
        outranks a leftover deliberate-stop file from the pre-replace unregister. */
    public static func shouldRegisterAtLaunch(
        deliberatelyStopped: Bool, rebindNeeded: Bool
    ) -> Bool {
        if rebindNeeded { return true }
        return !deliberatelyStopped
    }

    /** After a brief hello miss on a rebind, skip the throttle wait and
        re-register immediately. */
    public static func shouldForceReregisterAfterHelloMiss(rebindNeeded: Bool) -> Bool {
        rebindNeeded
    }
}
