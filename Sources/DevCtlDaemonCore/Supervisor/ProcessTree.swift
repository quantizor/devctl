import Darwin
import Foundation

/** Descendant enumeration via sysctl KERN_PROC_ALL. Group-directed signals miss
    processes that changed their own group (Foundation Process children setpgid;
    daemonizers setsid), so teardown signals the group AND every live descendant
    found by walking the parent-pid chain. The snapshot must be taken before the
    parent dies: orphans reparent to launchd and fall out of the chain. */
enum ProcessTree {
    /** All live descendants of `pid` (children, grandchildren, ...), excluding
        `pid` itself. Best-effort: a process spawned after the snapshot is missed. */
    static func descendants(of pid: pid_t) -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        /** Headroom: processes can appear between the size probe and the fetch. */
        size += size / 8
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&name, 4, &processes, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for info in processes.prefix(count) {
            childrenByParent[info.kp_eproc.e_ppid, default: []].append(info.kp_proc.p_pid)
        }
        var found: [pid_t] = []
        var queue: [pid_t] = [pid]
        while let parent = queue.popLast() {
            for child in childrenByParent[parent] ?? [] where child != parent {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /** Signals the process group and every stray descendant outside it. */
    static func signalTree(rootPid: pid_t, descendants: [pid_t], signal: Int32) {
        kill(-rootPid, signal)
        for pid in descendants where getpgid(pid) != rootPid {
            kill(pid, signal)
        }
    }
}
