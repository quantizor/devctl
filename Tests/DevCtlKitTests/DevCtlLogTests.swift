import Testing

@testable import DevCtlKit

/** Serialized: every case swaps the process-global `DevCtlLog.backend`, so
    parallel cases would clobber each other's recorder. */
@Suite(.serialized) struct DevCtlLogTests {
    /** Installs a recorder for the duration of `body`, then restores the default
        backend so one suite's swap never leaks into another. */
    private func withRecorder(_ body: (RecordingBackend) -> Void) {
        let previous = DevCtlLog.backend
        defer { DevCtlLog.backend = previous }
        let recorder = RecordingBackend()
        DevCtlLog.backend = recorder
        body(recorder)
    }

    @Test func categoryLoggerCapturesLevelAndCategory() {
        withRecorder { recorder in
            DevCtlLog.deeplink.info("dispatched ensure")
            DevCtlLog.deeplink.error("rejected slug")
            DevCtlLog.daemon.debug("tick")
            #expect(
                recorder.entries == [
                    .init(category: .deeplink, level: .info, message: "dispatched ensure"),
                    .init(category: .deeplink, level: .error, message: "rejected slug"),
                    .init(category: .daemon, level: .debug, message: "tick"),
                ])
        }
    }

    @Test func staticFormsMatchCategoryLoggers() {
        withRecorder { recorder in
            DevCtlLog.info(.app, "hello")
            DevCtlLog.error(.health, "probe failed")
            #expect(recorder.messages == ["hello", "probe failed"])
        }
    }

    @Test func resetClearsEntries() {
        withRecorder { recorder in
            DevCtlLog.supervisor.info("first")
            recorder.reset()
            DevCtlLog.supervisor.info("second")
            #expect(recorder.messages == ["second"])
        }
    }

    @Test func subsystemIsStable() {
        #expect(DevCtlLog.subsystem == "dev.quantizor.devctl")
    }
}
