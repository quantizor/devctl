import Foundation
import Testing
@testable import DevCtlKit

@Suite("SetupPlanner")
struct SetupPlannerTests {
    @Test func compareVersionsOrdersSemver() {
        #expect(SetupPlanner.compareVersions("1.0.0", "1.0.1") == .orderedAscending)
        #expect(SetupPlanner.compareVersions("1.2.0", "1.1.9") == .orderedDescending)
        #expect(SetupPlanner.compareVersions("1.2.0", "1.2.0") == .orderedSame)
        #expect(SetupPlanner.compareVersions("", "1.0.0") == .orderedAscending)
        #expect(SetupPlanner.compareVersions("2.0", "2.0.0") == .orderedSame)
    }

    @Test func shouldPresentOnFreshInstall() {
        #expect(
            SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: nil,
                stampVersion: nil,
                resourcesPresent: true))
    }

    @Test func shouldPresentWhenBundledNewerThanStamp() {
        #expect(
            SetupPlanner.shouldPresent(
                bundledVersion: "1.3.0",
                installedCLIVersion: "1.2.0",
                stampVersion: "1.2.0",
                resourcesPresent: true))
    }

    @Test func shouldSkipWhenVersionsMatch() {
        #expect(
            !SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: "1.2.0",
                stampVersion: "1.2.0",
                resourcesPresent: true))
    }

    @Test func shouldPresentWhenRunningOutsideApplicationsEvenIfVersionsMatch() {
        #expect(
            SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: "1.2.0",
                stampVersion: "1.2.0",
                resourcesPresent: true,
                runningOutsideApplications: true))
    }

    @Test func shouldSkipWithoutResources() {
        #expect(
            !SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: nil,
                stampVersion: nil,
                resourcesPresent: false))
        #expect(
            !SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: nil,
                stampVersion: nil,
                resourcesPresent: false,
                runningOutsideApplications: true))
    }

    @Test func isRunningOutsideApplicationsComparesCanonicalPaths() {
        #expect(
            SetupPlanner.isRunningOutsideApplications(
                bundlePath: "/Volumes/devctl/devctl.app"))
        #expect(
            !SetupPlanner.isRunningOutsideApplications(
                bundlePath: SetupPlanner.applicationsAppPath))
    }

    @Test func isMigrationDetectsPriorLayout() {
        #expect(SetupPlanner.isMigration(
            installedCLIExists: true, stampExists: false, launchAgentExists: false))
        #expect(SetupPlanner.isMigration(
            installedCLIExists: false, stampExists: false, launchAgentExists: true))
        #expect(
            !SetupPlanner.isMigration(
                installedCLIExists: false, stampExists: false, launchAgentExists: false))
    }

    @Test func cliDirectoryOnPATH() {
        let dir = SetupPlanner.defaultCLIDirectory(
            home: URL(fileURLWithPath: "/Users/test"))
        #expect(
            SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/usr/bin:\(dir.path):/bin", cliDirectory: dir))
        #expect(
            !SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/usr/bin:/bin", cliDirectory: dir))
    }

    @Test func harnessOffersDefaultCheckedOnlyWhenNeeded() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(
            at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appending(path: ".cursor"), withIntermediateDirectories: true)

        let cliPath = home.appending(path: ".local/bin/devctl").path
        let offersFresh = SetupPlanner.harnessOffers(home: home, installedCLIPath: cliPath)
        #expect(offersFresh.map(\.harness) == ["claude", "cursor"])
        #expect(offersFresh.allSatisfy { $0.defaultChecked && !$0.alreadyInstalled })

        let claudeSettings = """
            {"hooks":{"SessionStart":[{"hooks":[{"command":"\(cliPath) hook claude-session-start","type":"command"}],"matcher":"startup|resume|clear|compact"}]}}
            """
        try Data(claudeSettings.utf8).write(
            to: home.appending(path: ".claude/settings.json"))
        let cursorSettings = """
            {"hooks":{"sessionStart":[{"command":"\(cliPath) hook cursor-session-start"}]},"version":1}
            """
        try Data(cursorSettings.utf8).write(to: home.appending(path: ".cursor/hooks.json"))

        let offersInstalled = SetupPlanner.harnessOffers(home: home, installedCLIPath: cliPath)
        #expect(offersInstalled.count == 2)
        #expect(offersInstalled.allSatisfy { $0.alreadyInstalled && !$0.defaultChecked })
    }

    @Test func stampRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = root.appending(path: "setup.stamp")
        try SetupPlanner.writeStamp(version: "1.2.0", to: stamp)
        #expect(SetupPlanner.readStamp(at: stamp) == "1.2.0")
    }

    @Test func installBinaryStageAndRename() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "src-bin")
        let dest = root.appending(path: "bin/devctl")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: source)
        try SetupPlanner.installBinary(from: source, to: dest)
        #expect(FileManager.default.isExecutableFile(atPath: dest.path))
        let again = root.appending(path: "src-bin-2")
        try Data("#!/bin/sh\necho v2\n".utf8).write(to: again)
        try SetupPlanner.installBinary(from: again, to: dest)
        let body = try String(contentsOf: dest, encoding: .utf8)
        #expect(body.contains("v2"))
    }

    @Test func installAppBundleReplacesExisting() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let source = root.appending(path: "source.app")
        let dest = apps.appending(path: "devctl.app")
        try FileManager.default.createDirectory(
            at: source.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: source.appending(path: "Contents/marker"))
        try FileManager.default.createDirectory(
            at: dest.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appending(path: "Contents/marker"))
        try SetupPlanner.installAppBundle(from: source, to: dest)
        let body = try String(contentsOf: dest.appending(path: "Contents/marker"), encoding: .utf8)
        #expect(body == "v1")
    }
}
