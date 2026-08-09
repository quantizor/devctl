import Darwin
import Foundation

/** Shared test support. The fixture-server lookup lived in six copies that had
    already drifted apart (one checked existence rather than executability, and
    looked in one location instead of two), so a suite could fail to find a
    binary its neighbour found. */

/** Ports the unit suites allocate from. Reserved as a block so the stray reaper
    below can tell this suite's leftovers from any other devctl process on the
    machine, and so a new test picks its port from a documented range instead of
    guessing at a free number. */
enum TestPorts {
    /** Wide enough to cover the suites that draw a random port as well as the
        hand-assigned literals. It first stopped at 45500, which left
        `ResourceLockTests` outside it at 41_000 and 42_000: those fixtures went
        unreaped, and worse, they shared a range with `scripts/smoke.sh`, which
        draws its project-phase ports from 41000 too. Widening to reach them
        would have pointed the reaper at smoke's fixtures, so the suites moved
        in here instead. Anything added below must stay clear of smoke's 39000
        and 41000 ranges. */
    static let range = 45000..<46000

    static func owns(_ port: Int) -> Bool { range.contains(port) }
}

/** Path to the built fixture-server, or nil when it has not been built.

    Touching this also reaps strays exactly once per test process; see
    `strayFixturesReaped`. Every suite that spawns a fixture goes through here,
    so there is no separate step to forget. */
func fixtureServerExecutable() -> String? {
    _ = strayFixturesReaped
    return fixtureServerBinaryPath()
}

/** The lookup on its own, with no reaping, so the reaper can find the binary it
    is matching against without recursing back into itself. */
private func fixtureServerBinaryPath() -> String? {
    let candidates = [
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".build/debug/fixture-server"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/debug/fixture-server"),
    ]
    return candidates.map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) }
}

/** A Swift global initializes lazily and exactly once, which is the whole
    mechanism: the first suite to ask for the fixture pays for the sweep and
    every later one gets the cached value. */
private let strayFixturesReaped: Bool = {
    reapStrayFixtureServers()
    return true
}()

/** Kills fixture-servers left holding a unit-suite port by a run that was
    interrupted before it could stop them.

    A supervised child outliving its daemon is deliberate product behavior, not
    a leak, so the cleanup belongs to whoever spawned it. When a run is killed
    part way that owner is gone, and the next run fails somewhere unrelated with
    `port-held` naming a pid nothing is tracking. That cost this suite two runs
    before it was worth automating.

    Two conditions, both required, keep this from reaching a process it does not
    own. The parent must be gone (`ppid == 1`): a fixture belonging to a live run
    is parented by that run's test process, so a second concurrent `swift test`
    is untouched. And the command line must name a port this suite reserves,
    which is what keeps it away from `scripts/smoke.sh`, whose fixtures use their
    own ranges and are deliberately orphaned by its daemon-kill assertions. */
private func reapStrayFixtureServers() {
    guard let binary = fixtureServerBinaryPath() else { return }
    let name = (binary as NSString).lastPathComponent
    var killed: [pid_t] = []
    for candidate in runningProcesses()
    where shouldReapStray(command: candidate.command, parent: candidate.parent, binaryName: name) {
        kill(candidate.pid, SIGKILL)
        killed.append(candidate.pid)
    }
    /** Waits for the kernel to actually tear them down. SIGKILL returns
        immediately but the listening socket outlives the call by a moment, and a
        suite that spawned straight afterwards raced it and failed with
        `port-held` naming a pid this had just killed: a cleanup that does not
        wait for its own effect is only half a cleanup. */
    for _ in 0..<100 where !killed.isEmpty {
        killed = killed.filter { kill($0, 0) == 0 }
        if killed.isEmpty { break }
        usleep(20_000)
    }
}

/** The decision on its own, so both halves are testable without spawning
    anything: the two it must kill and, more importantly, the two it must not. */
func shouldReapStray(command: String, parent: pid_t, binaryName: String) -> Bool {
    /** Matched by name rather than by absolute path. A fixture launched through
        a relative path appears in `ps` exactly as invoked, so a full-path match
        silently skipped it, and a cleanup that quietly skips its target is
        indistinguishable from one that works. */
    guard command.contains(binaryName) else { return false }
    guard parent == 1 else { return false }
    return command.split(separator: " ").compactMap { Int($0) }.contains(where: TestPorts.owns)
}

private struct RunningProcess {
    let command: String
    let parent: pid_t
    let pid: pid_t
}

/** `ps` rather than the sysctl sweep in DevCtlDaemonCore, because the full
    command line is the thing being matched and `kinfo_proc` does not carry it. */
private func runningProcesses() -> [RunningProcess] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-A", "-o", "pid=,ppid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1])
        else { return nil }
        return RunningProcess(
            command: fields.dropFirst(2).joined(separator: " "), parent: parent, pid: pid)
    }
}
