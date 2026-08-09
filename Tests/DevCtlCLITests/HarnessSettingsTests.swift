import DevCtlKit
import Foundation
import Testing

@testable import devctl

/** `hook install` merges devctl's session hook into a settings file the user
    owns and devctl does not: `~/.claude/settings.json` holds every other hook,
    permission and preference the harness reads. The install writes the whole
    file back from what it read, so what the read does on a file it cannot parse
    decides whether the merge is a merge or a replacement. It used to answer with
    an empty dictionary, which the write then persisted as the entire file. */
@Suite struct HarnessSettingsTests {
    /** Stands in for a real adapter so these exercise the shared load/write pair
        rather than either harness's key layout. */
    private struct StubAdapter: HarnessAdapter {
        let name = "stub"
        let settingsURL: URL
        func install(devctlPath: String) throws -> String { "" }
    }

    private func inScratch(_ body: (StubAdapter) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "devctl-harness-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(StubAdapter(settingsURL: dir.appending(path: "settings.json")))
    }

    @Test func aMissingFileSeedsAnEmptyMerge() throws {
        try inScratch { adapter in
            let loaded = try adapter.loadSettings()
            #expect(loaded.isEmpty)
        }
    }

    /** Zero bytes is a seed rather than a loss: there is nothing in the file to
        erase, and refusing would strand anyone whose editor left one behind. */
    @Test func anEmptyFileSeedsAnEmptyMerge() throws {
        try inScratch { adapter in
            try Data().write(to: adapter.settingsURL)
            let loaded = try adapter.loadSettings()
            #expect(loaded.isEmpty)
        }
    }

    @Test func anExistingObjectLoadsWholeSoTheMergeKeepsIt() throws {
        try inScratch { adapter in
            try Data(#"{"permissions":{"allow":["Bash"]},"model":"opus"}"#.utf8)
                .write(to: adapter.settingsURL)
            let loaded = try adapter.loadSettings()
            #expect(loaded.count == 2)
            #expect(loaded["model"] as? String == "opus")
        }
    }

    /** The regression that matters. Before the refusal this returned `[:]`, and
        the caller wrote that back as the whole file: every unrelated setting in
        it was gone, reported as a successful install. */
    @Test(arguments: [
        #"{"model": "opus","#,  // truncated by a partial write
        #"["not", "an", "object"]"#,  // valid JSON, wrong top level
        "not json at all",
    ])
    func aFilePresentButUnparseableIsRefusedRatherThanReplaced(contents: String) throws {
        try inScratch { adapter in
            try Data(contents.utf8).write(to: adapter.settingsURL)
            #expect(throws: WireError.self) { try adapter.loadSettings() }
            /** The refusal is only worth anything if the file is still there
                afterwards, so assert the bytes, not just the throw. */
            let after = try String(contentsOf: adapter.settingsURL, encoding: .utf8)
            #expect(after == contents)
        }
    }

    /** Whoever hits this is looking at a file devctl declined to touch, so the
        message has to name the file, say why devctl stopped, and leave them a
        command to rerun. */
    @Test func theRefusalNamesTheFileAndWhatToDo() throws {
        try inScratch { adapter in
            try Data("nope".utf8).write(to: adapter.settingsURL)
            let error = #expect(throws: WireError.self) { try adapter.loadSettings() }
            #expect(error?.code == .configInvalid)
            #expect(error?.message.contains(adapter.settingsURL.path) == true)
            #expect(error?.hint == "devctl hook install")
        }
    }

    @Test func aWriteRoundTripsThroughTheLoad() throws {
        try inScratch { adapter in
            try adapter.writeSettings(["hooks": ["SessionStart": []], "keep": "me"])
            let loaded = try adapter.loadSettings()
            #expect(loaded["keep"] as? String == "me")
        }
    }
}
