import Darwin
import Foundation
import Testing

/** The stray reaper decides whether to SIGKILL a process, so the cases it must
    refuse matter more than the ones it acts on. Each was checked against real
    processes once; these pin the decision so it stays checked. */
@Suite struct TestSupportTests {
    private let binary = "fixture-server"

    @Test func reapsAnOrphanHoldingASuitePort() {
        #expect(
            shouldReapStray(
                command: "/Users/x/devctl/.build/debug/fixture-server --listen-tcp 45411",
                parent: 1, binaryName: binary))
    }

    /** Launched through a relative path, which is how it appears in `ps` when
        invoked that way. Matching the absolute path missed this and the miss was
        silent. */
    @Test func reapsAnOrphanInvokedThroughARelativePath() {
        #expect(
            shouldReapStray(
                command: "./.build/debug/fixture-server --listen-tcp 45411", parent: 1,
                binaryName: binary))
    }

    /** A fixture belonging to a live run is parented by that run's test process,
        so a second concurrent `swift test` must survive this untouched. */
    @Test func refusesAFixtureWithALiveParent() {
        #expect(
            shouldReapStray(
                command: "/Users/x/devctl/.build/debug/fixture-server --listen-tcp 45411",
                parent: 40100, binaryName: binary) == false)
    }

    /** scripts/smoke.sh allocates outside this range and deliberately orphans a
        fixture to prove children survive a daemon kill. Reaping that would break
        the assertion it exists to make. */
    @Test func refusesAnOrphanOutsideTheSuitePortRange() {
        #expect(
            shouldReapStray(
                command: "/Users/x/devctl/.build/debug/fixture-server --listen-tcp 39421",
                parent: 1, binaryName: binary) == false)
    }

    @Test func refusesAProcessThatIsNotTheFixture() {
        #expect(
            shouldReapStray(command: "/usr/bin/node server.js --port 45411", parent: 1, binaryName: binary)
                == false)
    }

    /** No port at all means nothing to squat, so there is no reason to kill it. */
    @Test func refusesAFixtureCarryingNoSuitePort() {
        #expect(
            shouldReapStray(
                command: "/Users/x/devctl/.build/debug/fixture-server --spawn-grandchild", parent: 1,
                binaryName: binary) == false)
    }

    @Test func theSuitePortRangeCoversTheBlockTheTestsUse() {
        #expect(TestPorts.owns(45001))
        #expect(TestPorts.owns(45426))
        #expect(TestPorts.owns(39421) == false)
        #expect(TestPorts.owns(41000) == false)
    }
}
