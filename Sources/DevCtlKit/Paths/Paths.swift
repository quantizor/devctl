import Foundation

/** On-disk layout: single home for every path the three products share. */
public struct DevCtlPaths: Sendable {
    public let dataDir: URL
    public let logsDir: URL

    public init(dataDir: URL? = nil, logsDir: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.dataDir = dataDir ?? home.appending(path: "Library/Application Support/devctl")
        self.logsDir = logsDir ?? home.appending(path: "Library/Logs/devctl")
    }

    public var daemonBinaryDir: URL { dataDir.appending(path: "bin") }
    public var daemonLog: URL { dataDir.appending(path: "daemon.log") }
    /** Login-shell PATH captured at install/start. The sealed in-bundle
        LaunchAgent cannot hold a dynamic PATH; the daemon merges this file
        into its environment at startup so children still find Homebrew tools. */
    public var agentPathFile: URL { dataDir.appending(path: "agent.path") }
    /** Written before replacing `/Applications/devctl.app` so the relaunched
        copy settles BTM before re-registering the helper (ad-hoc CDHash). */
    public var agentRebindFile: URL { dataDir.appending(path: "agent.rebind") }
    public var lockFile: URL { dataDir.appending(path: "daemon.lock") }
    /** Held resource locks (`project::resource` → holder + paused servers).
        Survives a daemon crash so mid-lock deaths can still resume what pause
        stopped. */
    public var locksFile: URL { dataDir.appending(path: "locks.json") }
    public var registryFile: URL { dataDir.appending(path: "registry.json") }
    public var stateFile: URL { dataDir.appending(path: "state.json") }
    public var stoppedIntentFile: URL { dataDir.appending(path: "stopped.intent") }

    /** The unix socket path, honoring DEVCTL_SOCKET and falling back under the
        sun_path 104-byte limit (long usernames, relocated homes). */
    public var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["DEVCTL_SOCKET"], !override.isEmpty {
            return override
        }
        let preferred = dataDir.appending(path: "daemon.sock").path
        return Self.fitsSunPath(preferred) ? preferred : "/tmp/devctl-\(getuid())/daemon.sock"
    }

    /** sun_path on Darwin is 104 bytes including the NUL terminator. */
    public static func fitsSunPath(_ path: String) -> Bool {
        path.utf8.count < 104
    }

    /** Per-server log directory: `<slug>-<hash8>/<server>`. The slug keeps paths
        human-readable; the hash keeps distinct projects with one basename apart. */
    public func serverLogDir(project: String, server: String) -> URL {
        let project = canonicalProjectPath(project)
        let slug = (project as NSString).lastPathComponent
            .lowercased()
            .replacing(/[^a-z0-9-]+/) { _ in "-" }
        return logsDir
            .appending(path: "\(slug)-\(Self.hash8(project))")
            .appending(path: server)
    }

    public var eventsFile: URL { dataDir.appending(path: "events.log") }

    /** Raw child-output spools, one per stream so out/err tagging survives; the
        child holds these fds, so they outlive the daemon. */
    public func spoolErrFile(project: String, server: String) -> URL {
        serverLogDir(project: project, server: server).appending(path: "err.spool")
    }

    public func spoolOutFile(project: String, server: String) -> URL {
        serverLogDir(project: project, server: server).appending(path: "out.spool")
    }

    public func structuredLogFile(project: String, server: String) -> URL {
        serverLogDir(project: project, server: server).appending(path: "current.log")
    }

    /** First 8 hex chars of SHA-256 over the canonical project path. */
    public static func hash8(_ string: String) -> String {
        SHA256Portable.digest(Array(string.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/** Canonicalizes a project path: absolute, symlinks resolved, on-disk case.
    CLI and daemon both use this so `~/code` symlinks or `/tmp` vs `/private/tmp`
    cannot mint two identities for one project. */
public func canonicalProjectPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    // On-disk case: FileManager gives the true spelling for existing paths.
    if let canonical = try? resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        return canonical
    }
    return resolved.path
}

/** Server identity used in the registry and state store. */
public func serverID(project: String, name: String) -> String {
    "\(project)::\(name)"
}

/** Atomic file persistence: temp + fsync + rename. Loads are defensive: a parse
    failure quarantines the file to `.corrupt-<timestamp>` and returns nil rather
    than crashing (a startup parse crash under launchd KeepAlive loops forever). */
public enum AtomicFile {
    /** Temp + fsync + rename. The temp name carries a per-call unique suffix, not
        just the pid: two writers inside one process (the app registers the agent
        at launch while its recovery poll writes the same file) would otherwise
        share a temp path and rename it out from under each other. */
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(
            path: ".\(url.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString)")
        try data.write(to: tmp)
        let fd = open(tmp.path, O_WRONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public static func loadDefensively<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.decoder().decode(type, from: data)
        } catch {
            let stamp = JSONCoding.formatISO8601(Date()).replacing(":", with: "-")
            let quarantine = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return nil
        }
    }
}

/** Minimal portable SHA-256 (FIPS 180-4), enough for 8-hex-char path hashing
    without importing CryptoKit into the core library. */
enum SHA256Portable {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        let k: [UInt32] = [
            0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
            0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
            0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
            0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
            0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
            0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
            0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
            0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
        ]
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(padded[base]) << 24) | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8) | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
            h[5] &+= f
            h[6] &+= g
            h[7] &+= hh
        }
        var out: [UInt8] = []
        for value in h {
            out.append(UInt8((value >> 24) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
