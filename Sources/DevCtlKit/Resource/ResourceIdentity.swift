import Foundation

public enum ResourceKind: String, Codable, Sendable {
    case directory
    case file
    case missing
    case symlink
}

/** A cheap, deterministic fingerprint of a lock resource's on-disk state, taken
    around a guarded command so a change made while a declaring server still held
    the old file open can be reported rather than silently accepted. */
public struct ResourceIdentity: Codable, Equatable, Sendable {
    public var bytes: Int64
    /** Hex SHA-256 over the sampled manifest. The manifest's exact line format
        is part of what this digest means; see ResourceFingerprint. */
    public var digest: String
    public var entryCount: Int
    /** Every sampled byte is inside the digest. False when a size or budget cap
        forced head-and-tail sampling, which is why a report says "sampled". */
    public var exact: Bool
    /** `<st_dev>:<st_ino>` of the root. A replaced file or a recreated directory
        changes this even when the bytes match, which is the case a content hash
        alone cannot see and the one that caused the incident. */
    public var inode: String
    public var kind: ResourceKind
    /** The entry cap clipped a directory walk. */
    public var truncated: Bool

    public init(
        bytes: Int64 = 0, digest: String = "", entryCount: Int = 0, exact: Bool = true,
        inode: String = "", kind: ResourceKind, truncated: Bool = false
    ) {
        self.bytes = bytes
        self.digest = digest
        self.entryCount = entryCount
        self.exact = exact
        self.inode = inode
        self.kind = kind
        self.truncated = truncated
    }
}

/** Why two identities differ, in the order a reader wants to hear it. */
public enum ResourceChangeReason: String, Sendable {
    case content
    case inode
    case kind
    case size
}

public enum ResourceChange: Equatable, Sendable {
    case appeared
    case changed(ResourceChangeReason)
    case disappeared
    case unchanged
}

public enum ResourceFingerprint {
    /** Files at or below this hash whole; larger ones contribute head, tail,
        size, and mtime. SHA256Portable takes a whole `[UInt8]` with no streaming
        entry point, so an exact digest of a large file costs a full buffer. */
    public static let fileByteCap = 8 << 20
    public static let sampleWindowBytes = 1 << 20
    public static let directoryContentBudget = 8 << 20
    public static let maxDepth = 6
    public static let maxEntries = 4096

    public static func capture(path: String) -> ResourceIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else { return ResourceIdentity(kind: .missing) }
        let inode = "\(info.st_dev):\(info.st_ino)"
        if info.st_mode & S_IFMT == S_IFLNK {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            return ResourceIdentity(
                bytes: Int64(info.st_size), digest: DevCtlPaths.hashHex(Array(target.utf8)),
                entryCount: 1, inode: inode, kind: .symlink)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            return captureDirectory(inode: inode, path: path)
        }
        let sample = sampleFile(path: path, size: Int64(info.st_size), stat: info)
        return ResourceIdentity(
            bytes: Int64(info.st_size), digest: DevCtlPaths.hashHex(sample.bytes), entryCount: 1,
            exact: sample.exact, inode: inode, kind: .file)
    }

    public static func compare(after: ResourceIdentity, before: ResourceIdentity)
        -> ResourceChange
    {
        if before.kind == .missing, after.kind == .missing { return .unchanged }
        if before.kind == .missing { return .appeared }
        if after.kind == .missing { return .disappeared }
        if before.kind != after.kind { return .changed(.kind) }
        if before.inode != after.inode { return .changed(.inode) }
        if before.bytes != after.bytes { return .changed(.size) }
        if before.digest != after.digest { return .changed(.content) }
        return .unchanged
    }

    /** A directory of sqlite files is the shape this exists for, and the caps
        are what keep a `path` aimed at a large tree from making every lock cost
        a full walk. */
    private static func captureDirectory(inode: String, path: String) -> ResourceIdentity {
        /** The enumerator hands back resolved paths (`/private/var/...` for a
            `/var/...` root), so the root is resolved too and each item's own
            absolute path is kept rather than rebuilt. Re-joining a stripped
            relative onto the unresolved root produced paths that existed nowhere
            and silently stat-failed, leaving an empty manifest that compared
            equal to every other empty one. */
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [(absolute: String, relative: String)] = []
        var clipped = false
        if let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let item as URL in walker {
                guard walker.level <= maxDepth else {
                    walker.skipDescendants()
                    continue
                }
                let absolute = item.path
                let relative =
                    absolute.hasPrefix(prefix)
                    ? String(absolute.dropFirst(prefix.count)) : item.lastPathComponent
                entries.append((absolute: absolute, relative: relative))
                if entries.count > maxEntries * 4 {
                    clipped = true
                    break
                }
            }
        }
        /** Sort before clipping so a truncated manifest is still deterministic:
            the enumerator's own order is unspecified, and clipping during the
            walk would make two captures of one tree disagree. */
        entries.sort { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
            clipped = true
        }
        var budget = directoryContentBudget
        var exact = !clipped
        var bytes: Int64 = 0
        var lines: [String] = []
        for entry in entries {
            let full = entry.absolute
            let relative = entry.relative
            var info = stat()
            guard lstat(full, &info) == 0 else { continue }
            bytes += Int64(info.st_size)
            let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec)
            var content = "-"
            if info.st_mode & S_IFMT == S_IFREG {
                if budget >= Int(info.st_size) {
                    let sample = sampleFile(path: full, size: Int64(info.st_size), stat: info)
                    content = DevCtlPaths.hashHex(sample.bytes)
                    budget -= Int(info.st_size)
                    exact = exact && sample.exact
                } else {
                    exact = false
                }
            }
            lines.append(
                "\(relative)\t\(info.st_dev):\(info.st_ino)\t\(info.st_size)\t\(mtime)\t\(content)")
        }
        return ResourceIdentity(
            bytes: bytes, digest: DevCtlPaths.hashHex(Array(lines.joined(separator: "\n").utf8)),
            entryCount: lines.count, exact: exact, inode: inode, kind: .directory,
            truncated: clipped)
    }

    /** Whole contents up to the cap, else head plus tail plus size and mtime.
        Above the cap a middle-only rewrite that preserves head, tail, size, and
        mtime is invisible; the identity says so through `exact`. */
    private static func sampleFile(path: String, size: Int64, stat info: stat) -> (
        bytes: [UInt8], exact: Bool
    ) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], false) }
        defer { try? handle.close() }
        if size <= Int64(fileByteCap) {
            let data = (try? handle.readToEnd()) ?? Data()
            return (Array(data), true)
        }
        let head = (try? handle.read(upToCount: sampleWindowBytes)) ?? Data()
        try? handle.seek(toOffset: UInt64(max(size - Int64(sampleWindowBytes), 0)))
        let tail = (try? handle.read(upToCount: sampleWindowBytes)) ?? Data()
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
        var bytes = Array(head)
        bytes.append(contentsOf: Array(tail))
        bytes.append(contentsOf: Array("\(size)\t\(mtime)".utf8))
        return (bytes, false)
    }
}
