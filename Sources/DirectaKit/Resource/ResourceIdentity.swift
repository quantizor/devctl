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
    /** A single file is hashed whole at any size: the digest streams, so peak
        memory is one chunk rather than the file, and there is no size above
        which a middle-only rewrite stops being visible.

        A directory keeps a byte budget, because its cost is the sum over every
        file in the tree and this runs twice per guarded command. Files past the
        budget contribute name, inode, size, and mtime but no content hash, and
        the identity reports `exact: false` so a caller is told the walk was
        partial instead of being left to assume it was not. */
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
                bytes: Int64(info.st_size), digest: DirectaPaths.hashHex(Array(target.utf8)),
                entryCount: 1, inode: inode, kind: .symlink)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            return captureDirectory(inode: inode, path: path)
        }
        /** An unreadable file is reported as inexact rather than given the digest
            of an empty read, which would compare equal to every other unreadable
            file and answer "unchanged" for a resource nobody could open. */
        guard let digest = DirectaPaths.hashHex(contentsOf: path) else {
            return ResourceIdentity(
                bytes: Int64(info.st_size), entryCount: 1, exact: false, inode: inode, kind: .file)
        }
        return ResourceIdentity(
            bytes: Int64(info.st_size), digest: digest, entryCount: 1, inode: inode, kind: .file)
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
            }
        }
        /** Sort before clipping so a truncated manifest is still deterministic.
            The walk deliberately does not stop early: the enumerator's order is
            unspecified, so breaking part way would pick a different subset run to
            run and make the fingerprint of an unchanged tree differ from itself.
            Collecting paths is cheap next to hashing them, and `maxDepth` already
            bounds how far the walk goes. */
        entries.sort { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }
        let clipped = entries.count > maxEntries
        if clipped { entries = Array(entries.prefix(maxEntries)) }
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
                if budget >= Int(info.st_size), let digest = DirectaPaths.hashHex(contentsOf: full) {
                    content = digest
                    budget -= Int(info.st_size)
                } else {
                    exact = false
                }
            }
            lines.append(
                "\(relative)\t\(info.st_dev):\(info.st_ino)\t\(info.st_size)\t\(mtime)\t\(content)")
        }
        return ResourceIdentity(
            bytes: bytes, digest: DirectaPaths.hashHex(Array(lines.joined(separator: "\n").utf8)),
            entryCount: lines.count, exact: exact, inode: inode, kind: .directory,
            truncated: clipped)
    }

}
