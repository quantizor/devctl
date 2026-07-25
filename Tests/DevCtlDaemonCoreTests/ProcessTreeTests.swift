import Darwin
import Foundation
import Testing

@testable import DevCtlDaemonCore

@Suite struct ProcessTreeTests {
    @Test func allocationRoundsUpAndNeverOverstatesBytes() {
        let stride = MemoryLayout<kinfo_proc>.stride
        let plan = ProcessTree.allocation(forProbedBytes: stride * 3 + 1)
        #expect(plan.capacity >= 4)
        #expect(plan.byteCount == plan.capacity * stride)
        #expect(plan.byteCount % stride == 0)
    }

    @Test func allocationZeroProbeIsEmpty() {
        let plan = ProcessTree.allocation(forProbedBytes: 0)
        #expect(plan.capacity == 0)
        #expect(plan.byteCount == 0)
    }

    @Test func shouldSignalRejectsMissingAndReusedPid() {
        let snap = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 5)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: nil) == false)
        let reused = ProcessIdentity(pid: 42, startSeconds: 200, startMicroseconds: 0)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: reused) == false)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: snap) == true)
    }

    @Test func failedDescendantsAreNotEmptySuccess() {
        /** Live sweep against a nonsense pid still returns .ok([]) (no children),
            never .failed. Failure is a sysctl errno path; assert the result type
            distinguishes the two shapes we care about. */
        let none = DescendantsResult.ok([])
        let fail = DescendantsResult.failed(errno: ENOMEM)
        #expect(none.identities.isEmpty)
        #expect(fail.identities.isEmpty)
        #expect(none != fail)
    }
}
