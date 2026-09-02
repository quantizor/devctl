import Darwin
import DevCtlKit
import Foundation
import Testing
import os

@testable import DevCtlDaemonCore

/** launchctl bootstrap is a machine-wide gui-domain mutation. Serialized so two
    cases cannot share a label or race bootout. */
@Suite(.serialized)
struct LaunchdJobLauncherTests {
    @Test func launchdJobGetsItsOwnJetsamCoalition() async throws {
        let parent = try #require(CoalitionIDs.read(of: getpid()))
        let (outFD, outURL) = try openSpool()
        let (errFD, errURL) = try openSpool()
        defer {
            close(outFD)
            close(errFD)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let spawned = OSAllocatedUnfairLock(initialState: pid_t(0))
        let outcome = await LaunchdJobLauncher().run(
            argv: ["/bin/sleep", "8"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
            onSpawn: { pid in
                spawned.withLock { $0 = pid }
                let ids = CoalitionIDs.read(of: pid)
                #expect(ids?.jetsam != parent.jetsam)
                #expect(ids?.resource != parent.resource)
                #expect(getpgid(pid) == pid)
                kill(pid, SIGTERM)
            }
        )
        try #require(spawned.withLock { $0 } > 0)
        switch outcome {
        case .signaled, .exited:
            break
        case .spawnFailed(let error):
            Issue.record("launchd spawn failed: \(error.message)")
        }
    }

    private func openSpool() throws -> (Int32, URL) {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "devctl-job-\(UUID().uuidString).log")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        try #require(fd >= 0)
        return (fd, url)
    }
}
