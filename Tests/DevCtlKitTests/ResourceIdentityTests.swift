import Foundation
import Testing

@testable import DevCtlKit

@Suite struct ResourceIdentityTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "devctl-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func hash8IsUnchangedByTheHashHexRefactor() {
        /** Log directory names on disk derive from this prefix, so it is pinned:
            a change here moves every project's log path. */
        #expect(DevCtlPaths.hash8("/Users/x/code/shop") == String(DevCtlPaths.hashHex(Array("/Users/x/code/shop".utf8)).prefix(8)))
        #expect(DevCtlPaths.hash8("").count == 8)
        #expect(DevCtlPaths.hashHex([]).count == 64)
    }

    @Test func aContentChangeAtEqualSizeIsDetected() throws {
        let dir = try scratch()
        let file = dir.appending(path: "db.sqlite")
        try Data("aaaa".utf8).write(to: file)
        let before = ResourceFingerprint.capture(path: file.path)
        try Data("bbbb".utf8).write(to: file)
        let after = ResourceFingerprint.capture(path: file.path)
        #expect(before.bytes == after.bytes)
        #expect(ResourceFingerprint.compare(after: after, before: before) != .unchanged)
    }

    /** The incident's shape: the file is removed and recreated, so a content
        hash alone can call it unchanged while the open handle still wins. */
    @Test func replacingAFileWithIdenticalBytesIsDetected() throws {
        let dir = try scratch()
        let file = dir.appending(path: "db.sqlite")
        try Data("same".utf8).write(to: file)
        let before = ResourceFingerprint.capture(path: file.path)
        try FileManager.default.removeItem(at: file)
        try Data("same".utf8).write(to: file)
        let after = ResourceFingerprint.capture(path: file.path)
        #expect(before.digest == after.digest)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.inode))
    }

    @Test func repeatedCaptureOfAnUnchangedDirectoryIsIdentical() throws {
        let dir = try scratch()
        for name in ["b.sqlite", "a.sqlite", "Z.sqlite", "é.sqlite"] {
            try Data(name.utf8).write(to: dir.appending(path: name))
        }
        let first = ResourceFingerprint.capture(path: dir.path)
        let second = ResourceFingerprint.capture(path: dir.path)
        #expect(first == second)
        #expect(ResourceFingerprint.compare(after: second, before: first) == .unchanged)
        #expect(first.kind == .directory)
        #expect(first.entryCount == 4)
    }

    @Test func directoryChangesOnAddRemoveAndModify() throws {
        let dir = try scratch()
        try Data("one".utf8).write(to: dir.appending(path: "a.sqlite"))
        let base = ResourceFingerprint.capture(path: dir.path)

        try Data("two".utf8).write(to: dir.appending(path: "b.sqlite"))
        let added = ResourceFingerprint.capture(path: dir.path)
        #expect(ResourceFingerprint.compare(after: added, before: base) != .unchanged)

        try Data("changed".utf8).write(to: dir.appending(path: "a.sqlite"))
        let modified = ResourceFingerprint.capture(path: dir.path)
        #expect(ResourceFingerprint.compare(after: modified, before: added) != .unchanged)

        try FileManager.default.removeItem(at: dir.appending(path: "b.sqlite"))
        let removed = ResourceFingerprint.capture(path: dir.path)
        #expect(ResourceFingerprint.compare(after: removed, before: modified) != .unchanged)
    }

    /** A d1 state directory is wiped and rebuilt, which is exactly the incident. */
    @Test func aRecreatedDirectoryIsDetectedEvenWithIdenticalContents() throws {
        let dir = try scratch()
        let state = dir.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("rows".utf8).write(to: state.appending(path: "db.sqlite"))
        let before = ResourceFingerprint.capture(path: state.path)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("rows".utf8).write(to: state.appending(path: "db.sqlite"))
        let after = ResourceFingerprint.capture(path: state.path)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.inode))
    }

    /** Over the entry cap the manifest is clipped, and the clip has to fall in
        the same place every time. Sorting before clipping is what guarantees
        that; stopping the walk early would pick a different subset run to run,
        because the enumerator's order is unspecified. */
    @Test func anOverCapDirectoryIsClippedDeterministically() throws {
        let dir = try scratch()
        for index in 0..<(ResourceFingerprint.maxEntries + 50) {
            try Data("x".utf8)
                .write(to: dir.appending(path: String(format: "f%05d", index)))
        }
        let first = ResourceFingerprint.capture(path: dir.path)
        let second = ResourceFingerprint.capture(path: dir.path)
        #expect(first.truncated)
        #expect(first.exact == false)
        #expect(first.entryCount == ResourceFingerprint.maxEntries)
        #expect(first == second)
    }

    @Test func missingThenPresentIsAppearedAndTheReverseIsDisappeared() throws {
        let dir = try scratch()
        let file = dir.appending(path: "later.sqlite")
        let absent = ResourceFingerprint.capture(path: file.path)
        #expect(absent.kind == .missing)
        try Data("x".utf8).write(to: file)
        let present = ResourceFingerprint.capture(path: file.path)
        #expect(ResourceFingerprint.compare(after: present, before: absent) == .appeared)
        #expect(ResourceFingerprint.compare(after: absent, before: present) == .disappeared)
        #expect(ResourceFingerprint.compare(after: absent, before: absent) == .unchanged)
    }

    @Test func aFileReplacedByADirectoryIsAKindChange() throws {
        let dir = try scratch()
        let target = dir.appending(path: "thing")
        try Data("x".utf8).write(to: target)
        let before = ResourceFingerprint.capture(path: target.path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let after = ResourceFingerprint.capture(path: target.path)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.kind))
    }

    /** Retargeting the link changes identity; editing what it points at does
        not, because the walk never follows it. */
    @Test func symlinksAreNotFollowed() throws {
        let dir = try scratch()
        let a = dir.appending(path: "a")
        let b = dir.appending(path: "b")
        try Data("one".utf8).write(to: a)
        try Data("two".utf8).write(to: b)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let before = ResourceFingerprint.capture(path: link.path)
        #expect(before.kind == .symlink)
        try Data("one-edited".utf8).write(to: a)
        #expect(ResourceFingerprint.compare(after: ResourceFingerprint.capture(path: link.path), before: before) == .unchanged)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        #expect(ResourceFingerprint.compare(after: ResourceFingerprint.capture(path: link.path), before: before) != .unchanged)
    }

    /** Above the cap the digest is head, tail, size, and mtime, so a tail edit
        is caught and a middle-only rewrite that preserves all four is not. The
        limit is asserted rather than left to prose. */
    @Test func aLargeFileIsSampledAndSaysSo() throws {
        let dir = try scratch()
        let file = dir.appending(path: "big.sqlite")
        let size = ResourceFingerprint.fileByteCap + 4096
        var bytes = Data(repeating: 0x41, count: size)
        try bytes.write(to: file)
        let before = ResourceFingerprint.capture(path: file.path)
        #expect(before.exact == false)

        bytes[size - 1] = 0x42
        try bytes.write(to: file)
        var attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = try #require(attributes[.modificationDate] as? Date)
        #expect(ResourceFingerprint.compare(after: ResourceFingerprint.capture(path: file.path), before: before) != .unchanged)

        /** The documented blind spot: same size, same mtime, same head and tail. */
        var middle = Data(repeating: 0x41, count: size)
        middle[size / 2] = 0x43
        middle[size - 1] = 0x42
        try middle.write(to: file)
        attributes[.modificationDate] = stamp
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let sampledAfter = ResourceFingerprint.capture(path: file.path)
        let tailEdited = ResourceFingerprint.capture(path: file.path)
        #expect(sampledAfter.digest == tailEdited.digest)
        #expect(sampledAfter.exact == false)
    }
}
