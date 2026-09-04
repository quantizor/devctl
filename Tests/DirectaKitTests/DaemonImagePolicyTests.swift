import Foundation
import Testing

@testable import DirectaKit

/** The daemon must never keep its process image on a mounted volume: a DMG shares
    the app's bundle id, so Launch Services can spawn ddirecta from the volume copy,
    which then pins the volume open. The policy decides when to re-exec the
    canonical installed binary instead. */
@Suite struct DaemonImagePolicyTests {
    private let appHelper = "/Applications/directa.app/Contents/Helpers/ddirecta"
    private let homeCLI = "/Users/x/.local/bin/ddirecta"
    private let volume = "/Volumes/directa/directa.app/Contents/Helpers/ddirecta"

    @Test func mountedVolumeReExecsTheInstalledHelper() {
        let decision = DaemonImagePolicy.decide(
            currentExecutable: volume,
            candidates: [appHelper, homeCLI],
            alreadyReexeced: false,
            fileExists: { $0 == appHelper })
        #expect(decision == .reexec(path: appHelper))
    }

    @Test func fallsBackToTheHomeCLIWhenNoAppIsInstalled() {
        let decision = DaemonImagePolicy.decide(
            currentExecutable: volume,
            candidates: [appHelper, homeCLI],
            alreadyReexeced: false,
            fileExists: { $0 == homeCLI })
        #expect(decision == .reexec(path: homeCLI))
    }

    @Test func bootVolumeImageRunsInPlace() {
        #expect(
            DaemonImagePolicy.decide(
                currentExecutable: appHelper, candidates: [appHelper, homeCLI],
                alreadyReexeced: false, fileExists: { _ in true }) == .runHere)
    }

    @Test func aReExecedProcessNeverReExecsAgain() {
        /** Belt-and-suspenders against a loop: a re-exec always targets a
            non-volume path, but even if the sentinel outlives a volume image the
            guard refuses a second hop. */
        #expect(
            DaemonImagePolicy.decide(
                currentExecutable: volume, candidates: [appHelper],
                alreadyReexeced: true, fileExists: { _ in true }) == .runHere)
    }

    @Test func runsInPlaceWhenNoCanonicalBinaryExistsElsewhere() {
        /** Exiting under KeepAlive would respawn the same volume image in a tight
            loop, so running in place is the last resort. */
        #expect(
            DaemonImagePolicy.decide(
                currentExecutable: volume, candidates: [appHelper, homeCLI],
                alreadyReexeced: false, fileExists: { _ in false }) == .runHere)
    }

    @Test func neverReExecsToAnotherVolumePathOrToItself() {
        /** A candidate that is itself on a volume, or that equals the current
            image, is not an escape. */
        #expect(
            DaemonImagePolicy.decide(
                currentExecutable: volume, candidates: [volume, "/Volumes/other/ddirecta"],
                alreadyReexeced: false, fileExists: { _ in true }) == .runHere)
    }

    @Test func mountedVolumeDetection() {
        #expect(DaemonImagePolicy.isUnderMountedVolume("/Volumes/directa/x"))
        #expect(DaemonImagePolicy.isUnderMountedVolume("/Volumes"))
        #expect(!DaemonImagePolicy.isUnderMountedVolume("/Applications/directa.app/x"))
        #expect(!DaemonImagePolicy.isUnderMountedVolume("/VolumesData/x"))
        #expect(!DaemonImagePolicy.isUnderMountedVolume("/Users/x/.local/bin/ddirecta"))
    }
}
