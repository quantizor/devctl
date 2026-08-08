import Foundation
import Testing

@testable import DevCtlKit

/** A server name comes from a repo's committed devservers.json, so it reaches
    the log path as attacker-supplied text. `URL.appending(path:)` keeps `..` and
    `/` verbatim and the kernel resolves them at `createDirectory` and `open`, so
    an unsanitized name let a config choose where the daemon wrote raw child
    output. */
@Suite struct ServerPathComponentTests {
    @Test func anOrdinaryNameIsUntouched() {
        #expect(DevCtlPaths.serverPathComponent("web") == "web")
        #expect(DevCtlPaths.serverPathComponent("api-v2_3") == "api-v2_3")
    }

    @Test(arguments: [
        "../../../etc", "a/b", "/absolute", "..", ".", "", "with:colon",
    ])
    func nothingEscapesItsDirectory(name: String) {
        let component = DevCtlPaths.serverPathComponent(name)
        #expect(!component.contains("/"))
        #expect(component != "." && component != "..")
        #expect(!component.isEmpty)
    }

    /** The proof that matters is about the filesystem, not the string: resolving
        the built URL must stay under the logs directory. */
    @Test func aTraversingNameStaysUnderTheLogsDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "devctl-paths-\(UUID().uuidString)")
        let paths = DevCtlPaths(
            dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
        let dir = paths.serverLogDir(
            project: "/tmp/proj", server: "../../../../devctl-escape-probe")
        let resolved = URL(fileURLWithPath: dir.path).standardizedFileURL.path
        let root = URL(fileURLWithPath: paths.logsDir.path).standardizedFileURL.path
        #expect(resolved.hasPrefix(root + "/"), "escaped to \(resolved)")
    }

    /** Two names that flatten to the same text must not share a log directory,
        or one server's output lands in another's file. */
    @Test func namesThatFlattenAlikeStayApart() {
        #expect(
            DevCtlPaths.serverPathComponent(".")
                != DevCtlPaths.serverPathComponent(".."))
    }
}
