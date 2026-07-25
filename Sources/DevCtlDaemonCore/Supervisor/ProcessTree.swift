import Darwin
import Foundation

/** A process identity that survives PID reuse: pid alone is not enough across a
    grace window, because macOS can recycle the number. Start time comes from
    `kinfo_proc.kp_proc.p_starttime`. */
public struct ProcessIdentity: Hashable, Sendable, Equatable {
    public let pid: pid_t
    public let startMicroseconds: suseconds_t
    public let startSeconds: time_t

    public init(pid: pid_t, startSeconds: time_t, startMicroseconds: suseconds_t) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
        self.startSeconds = startSeconds
    }

    init(_ info: kinfo_proc) {
        self.pid = info.kp_proc.p_pid
        self.startMicroseconds = info.kp_proc.p_starttime.tv_usec
        self.startSeconds = info.kp_proc.p_starttime.tv_sec
    }
}

/** Result of a descendant sweep. Failure must not look like "no children": a
    silent empty list drops the escaped-descendant half of teardown. */
public enum DescendantsResult: Sendable, Equatable {
    case failed(errno: Int32)
    case ok([ProcessIdentity])

    public var identities: [ProcessIdentity] {
        switch self {
        case .failed: []
        case .ok(let ids): ids
        }
    }

    public var pids: [pid_t] { identities.map(\.pid) }
}

/** Descendant enumeration via sysctl KERN_PROC_ALL. Group-directed signals miss
    processes that changed their own group (Foundation Process children setpgid;
    daemonizers setsid), so teardown signals the group AND every live descendant
    found by walking the parent-pid chain. The snapshot must be taken before the
    parent dies: orphans reparent to launchd and fall out of the chain. */
public enum ProcessTree {
    /** All live descendants of `pid` (children, grandchildren, ...), excluding
        `pid` itself. Best-effort: a process spawned after the snapshot is missed. */
    public static func descendants(of pid: pid_t) -> DescendantsResult {
        switch fetchProcessTable() {
        case .failed(let errno):
            return .failed(errno: errno)
        case .ok(let table):
            var childrenByParent: [pid_t: [ProcessIdentity]] = [:]
            for identity in table {
                childrenByParent[identity.parent, default: []].append(identity.process)
            }
            var found: [ProcessIdentity] = []
            var queue: [pid_t] = [pid]
            while let parent = queue.popLast() {
                for child in childrenByParent[parent] ?? [] where child.pid != parent {
                    found.append(child)
                    queue.append(child.pid)
                }
            }
            return .ok(found)
        }
    }

    /** Whether a snapshotted identity still names the same process. A nil live
        identity means the pid is gone; a start-time mismatch means reuse. */
    public static func shouldSignal(snapshotted: ProcessIdentity, live: ProcessIdentity?) -> Bool {
        guard let live else { return false }
        return snapshotted == live
    }

    /** Round a probed byte count up to whole `kinfo_proc` entries with 12.5%
        headroom, then return capacity and the exact allocated byte count to
        pass to sysctl (never advertise past the allocation). */
    public static func allocation(forProbedBytes probed: Int) -> (capacity: Int, byteCount: Int) {
        let stride = MemoryLayout<kinfo_proc>.stride
        guard probed > 0, stride > 0 else { return (0, 0) }
        let withHeadroom = probed + probed / 8
        let capacity = max(1, (withHeadroom + stride - 1) / stride)
        return (capacity, capacity * stride)
    }

    /** Signals the process group and every stray descendant outside it.
        When `revalidate` is true, skip identities whose start time no longer
        matches (PID reuse after a grace window). */
    public static func signalTree(
        rootPid: pid_t,
        descendants: [ProcessIdentity],
        signal: Int32,
        revalidate: Bool = false
    ) {
        kill(-rootPid, signal)
        for identity in descendants {
            if revalidate {
                let live = liveIdentity(of: identity.pid)
                guard shouldSignal(snapshotted: identity, live: live) else { continue }
            }
            if getpgid(identity.pid) != rootPid {
                kill(identity.pid, signal)
            }
        }
    }

    /** Individually SIGKILL snapshotted PIDs that still match, used when the
        root is already gone so group-directed kill no longer applies. */
    public static func escalateIndividuals(_ identities: [ProcessIdentity]) {
        for identity in identities {
            let live = liveIdentity(of: identity.pid)
            guard shouldSignal(snapshotted: identity, live: live) else { continue }
            kill(identity.pid, SIGKILL)
        }
    }

    private struct TableRow: Sendable {
        let parent: pid_t
        let process: ProcessIdentity
    }

    private enum TableResult {
        case failed(errno: Int32)
        case ok([TableRow])
    }

    /** QA1123 shape: 3-level MIB, size probe, rounded allocation, retry ENOMEM. */
    private static func fetchProcessTable() -> TableResult {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<8 {
            var probed = 0
            guard sysctl(&mib, 3, nil, &probed, nil, 0) == 0, probed > 0 else {
                return .failed(errno: errno)
            }
            let plan = allocation(forProbedBytes: probed)
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: plan.capacity)
            var length = plan.byteCount
            let status = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                sysctl(&mib, 3, ptr.baseAddress, &length, nil, 0)
            }
            if status == 0 {
                let count = length / MemoryLayout<kinfo_proc>.stride
                let rows = buffer.prefix(count).map { info in
                    TableRow(parent: info.kp_eproc.e_ppid, process: ProcessIdentity(info))
                }
                return .ok(rows)
            }
            if errno == ENOMEM { continue }
            return .failed(errno: errno)
        }
        return .failed(errno: ENOMEM)
    }

    private static func liveIdentity(of pid: pid_t) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var length = MemoryLayout<kinfo_proc>.stride
        var info = kinfo_proc()
        guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length >= MemoryLayout<kinfo_proc>.stride
        else { return nil }
        guard info.kp_proc.p_pid == pid else { return nil }
        return ProcessIdentity(info)
    }
}
