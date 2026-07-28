import Testing

@testable import DevCtlKit

@Suite struct CrashNotificationPolicyTests {
    @Test func notifiesUnexpectedCrashAndFailure() {
        #expect(CrashNotificationPolicy.shouldNotify(kind: .crashed, detail: "code=1"))
        #expect(CrashNotificationPolicy.shouldNotify(kind: .failed, detail: "ENOENT"))
        #expect(CrashNotificationPolicy.shouldNotify(kind: .crashed, detail: nil))
    }

    @Test func skipsExpectedDaemonBounce() {
        #expect(
            CrashNotificationPolicy.shouldNotify(kind: .crashed, detail: "daemon-restart")
                == false)
        #expect(
            CrashNotificationPolicy.shouldNotify(
                kind: .crashed, detail: "daemon-restart: orphan pid 12 bounced") == false)
    }

    @Test func ignoresNonTerminalKinds() {
        #expect(CrashNotificationPolicy.shouldNotify(kind: .stopped, detail: "daemon-restart") == false)
        #expect(CrashNotificationPolicy.shouldNotify(kind: .started, detail: nil) == false)
    }
}
