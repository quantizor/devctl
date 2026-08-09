import Foundation
import Testing

@testable import DevCtlKit

@Suite("AppInstancePolicy")
struct AppInstancePolicyTests {
    private func instance(
        _ path: String, _ pid: Int32, _ secondsAgo: TimeInterval? = nil
    ) -> AppInstance {
        AppInstance(
            bundlePath: path,
            launchDate: secondsAgo.map { Date(timeIntervalSince1970: 1_000_000 - $0) },
            processIdentifier: pid)
    }

    /** The reported defect: `open -n` (which is what the DMG handoff asks for)
        leaves two copies at one path, each polling and each drawing a menu bar
        item. The newer one leaves. */
    @Test func aSecondCopyAtTheSamePathStandsDown() {
        let incumbent = instance("/Applications/devctl.app", 100, 60)
        let newcomer = instance("/Applications/devctl.app", 200, 1)
        #expect(AppInstancePolicy.shouldStandDown(own: newcomer, running: [incumbent, newcomer]))
        #expect(!AppInstancePolicy.shouldStandDown(own: incumbent, running: [incumbent, newcomer]))
    }

    /** The one time two copies are correct. The volume copy replaces the
        Applications copy and waits for it to come up before quitting, so a policy
        keyed on the bundle id rather than the path would quit the copy the
        handoff is waiting for and leave nothing running. */
    @Test func theDMGHandoffKeepsBothCopies() {
        let volume = instance("/Volumes/devctl/devctl.app", 100, 60)
        let applications = instance("/Applications/devctl.app", 200, 1)
        let running = [volume, applications]
        #expect(!AppInstancePolicy.shouldStandDown(own: volume, running: running))
        #expect(!AppInstancePolicy.shouldStandDown(own: applications, running: running))
    }

    /** A process must not read itself as its own twin: the list it is given
        includes it. */
    @Test func aCopyIsNotItsOwnTwin() {
        let only = instance("/Applications/devctl.app", 100, 60)
        #expect(!AppInstancePolicy.shouldStandDown(own: only, running: [only]))
    }

    /** Two copies launched in the same instant is the case a launch-date
        comparison alone gets wrong: neither is older, so either both stay (the
        bug) or both leave (worse). Exactly one must answer true. */
    @Test func aTieIsBrokenSoExactlyOneLeaves() {
        let first = instance("/Applications/devctl.app", 100, 5)
        let second = instance("/Applications/devctl.app", 200, 5)
        let running = [first, second]
        let leaving = [first, second].filter {
            AppInstancePolicy.shouldStandDown(own: $0, running: running)
        }
        #expect(leaving == [second])
    }

    /** `NSRunningApplication.launchDate` is optional, so the order has to stay
        total when one side or both sides are missing. Both directions are
        asserted because the two processes evaluate this from opposite sides and
        must not agree that the other should stay. */
    @Test func aMissingLaunchDateStillDecides() {
        let dated = instance("/Applications/devctl.app", 300, 5)
        let undated = instance("/Applications/devctl.app", 100, nil)
        let mixed = [dated, undated]
        #expect(AppInstancePolicy.shouldStandDown(own: undated, running: mixed))
        #expect(!AppInstancePolicy.shouldStandDown(own: dated, running: mixed))

        let neither = [instance("/Applications/devctl.app", 100, nil),
                       instance("/Applications/devctl.app", 200, nil)]
        #expect(!AppInstancePolicy.shouldStandDown(own: neither[0], running: neither))
        #expect(AppInstancePolicy.shouldStandDown(own: neither[1], running: neither))
    }

    /** Three at once, which the manual relaunch button racing the automatic call
        can produce: everything but the oldest leaves rather than one pairing
        cancelling out. */
    @Test func onlyTheOldestOfSeveralStays() {
        let running = [
            instance("/Applications/devctl.app", 100, 30),
            instance("/Applications/devctl.app", 200, 20),
            instance("/Applications/devctl.app", 300, 10),
        ]
        let staying = running.filter {
            !AppInstancePolicy.shouldStandDown(own: $0, running: running)
        }
        #expect(staying == [running[0]])
    }
}
