import DevCtlDaemonCore
import DevCtlKit
import Foundation

/** devctld: the daemon. Runs identically under launchd and --foreground; the only
    difference is who started it. Exits nonzero on startup failure so launchd's
    KeepAlive={SuccessfulExit:false} relaunches crashes but honors clean exits. */

var socketOverride: String?
var dataDirOverride: String?
var logsDirOverride: String?
var foreground = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--foreground":
        foreground = true
    case "--socket":
        socketOverride = argIterator.next()
    case "--data-dir":
        dataDirOverride = argIterator.next()
    case "--logs-dir":
        logsDirOverride = argIterator.next()
    case "--version":
        print(DevCtlVersion.version)
        exit(0)
    default:
        FileHandle.standardError.write(Data("devctld: unknown argument \(arg)\n".utf8))
        exit(2)
    }
}

if let socketOverride {
    setenv("DEVCTL_SOCKET", socketOverride, 1)
}

let paths = DevCtlPaths(
    dataDir: dataDirOverride.map { URL(fileURLWithPath: $0) },
    logsDir: logsDirOverride.map { URL(fileURLWithPath: $0) }
)

do {
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("devctld: cannot create data/logs dirs: \(error)\n".utf8))
    exit(1)
}

/** Single-instancing: an exclusive flock held for the daemon's lifetime. Only the
    lock holder may unlink and rebind the socket, so stale-socket takeover cannot
    race between two starting daemons. */
let lockFD = open(paths.lockFile.path, O_WRONLY | O_CREAT, 0o600)
guard lockFD >= 0 else {
    FileHandle.standardError.write(Data("devctld: cannot open lock file: \(String(cString: strerror(errno)))\n".utf8))
    exit(1)
}
guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    FileHandle.standardError.write(Data("devctld: another devctld instance holds \(paths.lockFile.path); exiting\n".utf8))
    exit(0)
}

/** Raise the fd ceiling: launchd jobs default to a 256 soft limit, and a dozen
    servers plus log subscribers approaches it. */
var limit = rlimit()
if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
    limit.rlim_cur = min(limit.rlim_max, rlim_t(8192))
    setrlimit(RLIMIT_NOFILE, &limit)
}

let registry = Registry(paths: paths)
let router = Router(launcher: SubprocessLauncher(), paths: paths, registry: registry)

let server: ControlServer
do {
    server = try ControlServer(router: router, socketPath: paths.socketPath)
} catch {
    FileHandle.standardError.write(Data("devctld: cannot bind \(paths.socketPath): \(error)\n".utf8))
    exit(1)
}
server.start()

/** Graceful termination: drain-stop every supervised server through the normal
    teardown path, then exit 0 (a deliberate stop must not trigger KeepAlive). */
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
terminationSource.setEventHandler {
    Task {
        await router.drainAll()
        exit(0)
    }
}
terminationSource.resume()

FileHandle.standardError.write(
    Data("devctld \(DevCtlVersion.version) listening on \(paths.socketPath) (pid \(getpid()))\n".utf8))

dispatchMain()
