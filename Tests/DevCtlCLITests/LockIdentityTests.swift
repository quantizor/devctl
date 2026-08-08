import DevCtlKit
import Foundation
import Testing

@testable import devctl

/** The incident: a session wiped a local database directory to re-run migrations
    under `--no-pause`. The lock serialized access, the still-running server held
    the old file open and flushed its cached pages back over the migrated one, and
    the migration reported success while the seeded rows were gone. Nothing in the
    output distinguished that from a clean run. */
@Suite struct LockIdentityTests {
    private let file = ResourceIdentity(
        bytes: 10, digest: "aaa", entryCount: 1, inode: "1:2", kind: .file)

    @Test func changedUnderNoPauseWithALiveServerIsAFault() throws {
        let after = ResourceIdentity(
            bytes: 10, digest: "aaa", entryCount: 1, inode: "1:9", kind: .file)
        let verdict = LockIdentityVerdict.of(
            after: after, before: file, live: ["db"], resource: "d1",
            statePath: "/p/state")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault, got \(verdict)")
            return
        }
        #expect(error.code == .resourceMutated)
        #expect(
            error.message
                == "resource 'd1' state at /p/state changed (it was replaced) while db stayed running under --no-pause. That server holds the old state open and can write its cached pages back over the change, so what is on disk is not what the command wrote."
        )
        #expect(
            error.hint == "devctl stop db && devctl lock d1 -- <command> && devctl ensure db")
    }

    @Test func theFaultHintListsEveryLiveServerSorted() throws {
        let after = ResourceIdentity(
            bytes: 11, digest: "bbb", entryCount: 1, inode: "1:2", kind: .file)
        let verdict = LockIdentityVerdict.of(
            after: after, before: file, live: ["web", "db"], resource: "d1", statePath: "/p/s")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault")
            return
        }
        #expect(
            error.hint
                == "devctl stop db && devctl stop web && devctl lock d1 -- <command> && devctl ensure db && devctl ensure web")
    }

    /** Under the default paused mode a change is the entire point, so it is
        information rather than a fault. */
    @Test func changedWithNothingRunningIsANote() {
        let after = ResourceIdentity(
            bytes: 12, digest: "ccc", entryCount: 1, inode: "1:2", kind: .file)
        let verdict = LockIdentityVerdict.of(
            after: after, before: file, live: [], resource: "d1", statePath: "/p/state")
        #expect(
            verdict
                == .note(
                    "devctl lock: note: 'd1' state at /p/state changed during this hold (its size changed). Nothing was running against it."
                ))
    }

    @Test func unchangedStateIsSilent() {
        #expect(
            LockIdentityVerdict.of(
                after: file, before: file, live: ["db"], resource: "d1", statePath: "/p/s")
                == .silent)
    }

    @Test func aRemovedResourceUnderNoPauseReadsAsRemoved() throws {
        let gone = ResourceIdentity(kind: .missing)
        let verdict = LockIdentityVerdict.of(
            after: gone, before: file, live: ["db"], resource: "d1", statePath: "/p/s")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault")
            return
        }
        #expect(error.message.contains("(it was removed)"))
    }

    @Test func aCreatedResourceUnderNoPauseReadsAsCreated() throws {
        let verdict = LockIdentityVerdict.of(
            after: file, before: ResourceIdentity(kind: .missing), live: ["db"], resource: "d1",
            statePath: "/p/s")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault")
            return
        }
        #expect(error.message.contains("(it was created)"))
    }
}
