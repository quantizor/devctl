import Foundation
import Testing

@testable import DirectaKit

/** The response-deadline clamp exists because the value flows from a
    caller-supplied `--timeout`, and `Int(Double)` traps on a non-finite or
    out-of-range input. Before the clamp, `directa ensure --timeout inf` crashed
    the process with a runtime trap instead of running. */
@Suite struct DaemonClientTimeoutTests {
    @Test func infiniteAndNaNDegradeToTheDefault() {
        #expect(DaemonClient.clampedResponseTimeout(.infinity) == 120)
        #expect(DaemonClient.clampedResponseTimeout(-.infinity) == 120)
        #expect(DaemonClient.clampedResponseTimeout(.nan) == 120)
    }

    @Test func finiteValuesPassThroughWithinRange() {
        #expect(DaemonClient.clampedResponseTimeout(30) == 30)
        #expect(DaemonClient.clampedResponseTimeout(0) == 0)
    }

    @Test func outOfRangeValuesClampToTheEdges() {
        /** A negative deadline is meaningless; floor it at zero. A value past a
            day is far beyond any real deadline and would risk the Int conversion,
            so it caps rather than overflows. */
        #expect(DaemonClient.clampedResponseTimeout(-5) == 0)
        #expect(DaemonClient.clampedResponseTimeout(1_000_000_000) == 86_400)
    }
}
