import Foundation
import Testing

@testable import DevCtlKit

@Suite struct InstallShadowTests {
    @Test func onlyHomebrewCLIIsNotAShadow() {
        #expect(
            InstallShadow.detect(
                foreignApp: nil, homebrewCLI: "/opt/homebrew/bin/devctl", localCLI: nil,
                localDaemon: nil, pathWinner: "/opt/homebrew/bin/devctl"
            ).isEmpty)
    }

    @Test func onlyManualCLIIsNotAShadow() {
        #expect(
            InstallShadow.detect(
                foreignApp: nil, homebrewCLI: nil, localCLI: "/Users/x/.local/bin/devctl",
                localDaemon: "/Users/x/.local/bin/devctld", pathWinner: "/Users/x/.local/bin/devctl"
            ).isEmpty)
    }

    @Test func coexistingCLIsWarnAndNameTheCleanup() {
        let findings = InstallShadow.detect(
            foreignApp: nil, homebrewCLI: "/opt/homebrew/bin/devctl",
            localCLI: "/Users/x/.local/bin/devctl", localDaemon: "/Users/x/.local/bin/devctld",
            pathWinner: "/Users/x/.local/bin/devctl")
        #expect(findings.count == 1)
        #expect(findings[0].detail.contains("two devctl CLIs are installed"))
        #expect(findings[0].detail.contains("/opt/homebrew/bin/devctl"))
        #expect(findings[0].detail.contains("a bare `devctl` runs /Users/x/.local/bin/devctl"))
        #expect(findings[0].remedy == "rm /Users/x/.local/bin/devctl /Users/x/.local/bin/devctld")
    }

    @Test func coexistingCLIsWithNoResolvablePathWinnerStillWarn() {
        let findings = InstallShadow.detect(
            foreignApp: nil, homebrewCLI: "/opt/homebrew/bin/devctl",
            localCLI: "/Users/x/.local/bin/devctl", localDaemon: nil, pathWinner: nil)
        #expect(findings.count == 1)
        #expect(findings[0].detail.contains("PATH order decides which one runs"))
        #expect(findings[0].remedy == "rm /Users/x/.local/bin/devctl")
    }

    @Test func foreignApplicationsAppWarnsWithReinstall() {
        let findings = InstallShadow.detect(
            foreignApp: "/Applications/devctl.app", homebrewCLI: "/opt/homebrew/bin/devctl",
            localCLI: nil, localDaemon: nil, pathWinner: nil)
        #expect(findings.count == 1)
        #expect(
            findings[0].detail.contains("/Applications/devctl.app is not the Homebrew-installed app"))
        #expect(findings[0].remedy.hasPrefix("brew reinstall --cask"))
    }

    @Test func bothProblemsProduceTwoFindings() {
        let findings = InstallShadow.detect(
            foreignApp: "/Applications/devctl.app", homebrewCLI: "/opt/homebrew/bin/devctl",
            localCLI: "/Users/x/.local/bin/devctl", localDaemon: "/Users/x/.local/bin/devctld",
            pathWinner: "/Users/x/.local/bin/devctl")
        #expect(findings.count == 2)
    }

    @Test func firstOnPathResolvesInPathOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "devctl-shadow-\(UUID().uuidString)")
        let dirA = base.appending(path: "a")
        let dirB = base.appending(path: "b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        /** Binary only in the second dir: PATH order picks the second. */
        FileManager.default.createFile(atPath: dirB.appending(path: "devctl").path, contents: nil)
        #expect(
            InstallShadow.firstOnPath(
                binary: "devctl", pathEnv: "\(dirA.path):\(dirB.path)",
                fileManager: .default) == dirB.appending(path: "devctl").path)

        /** Binary in both: the first dir wins, matching shell resolution. */
        FileManager.default.createFile(atPath: dirA.appending(path: "devctl").path, contents: nil)
        #expect(
            InstallShadow.firstOnPath(
                binary: "devctl", pathEnv: "\(dirA.path):\(dirB.path)",
                fileManager: .default) == dirA.appending(path: "devctl").path)

        /** Absent everywhere: no winner. */
        #expect(
            InstallShadow.firstOnPath(binary: "nope", pathEnv: dirA.path, fileManager: .default)
                == nil)
    }
}
