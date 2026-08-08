import DevCtlDaemonCore
import DevCtlKit
import Foundation
import IOKit
import IOKit.pwr_mgt

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

/** Raise the fd ceiling only when below the target: launchd jobs default to a
    256 soft limit, and a dozen servers plus log subscribers approaches it. Never
    lower an already-higher soft limit. */
var limit = rlimit()
if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
    let target = min(limit.rlim_max, rlim_t(8192))
    if limit.rlim_cur < target {
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            FileHandle.standardError.write(
                Data(
                    "devctld: setrlimit(RLIMIT_NOFILE) failed: \(String(cString: strerror(errno)))\n"
                        .utf8))
        }
    }
}

/** A running daemon is proof any prior deliberate-stop intent is spent. */
try? FileManager.default.removeItem(at: paths.stoppedIntentFile)

/** Merge the install-time login PATH before any child spawn so Homebrew tools
    stay findable under a sealed in-bundle LaunchAgent. */
LaunchdAdmin.applyAgentPathToProcess(paths: paths)

let registry = Registry(paths: paths)
let router = Router(launcher: SubprocessLauncher(), paths: paths, registry: registry)

/** Sleep/wake awareness: health probes pause during sleep and get a grace
    window on wake so lid-open does not flap every server unhealthy. IOKit
    message macros (`kIOMessageCanSystemSleep` et al.) do not bridge into Swift;
    these named values match IOMessage.h (`iokit_common_msg`). */
enum PowerMessage {
    static let canSystemSleep: natural_t = 0xE000_0270
    static let systemHasPoweredOn: natural_t = 0xE000_0300
    static let systemWillSleep: natural_t = 0xE000_0280
}
final class PowerContext {
    var rootPort: io_connect_t = 0
}
let powerContext = PowerContext()
var powerNotifier: io_object_t = 0
var powerPort: IONotificationPortRef?
powerContext.rootPort = IORegisterForSystemPower(
    Unmanaged.passUnretained(powerContext).toOpaque(),
    &powerPort,
    { refcon, _, messageType, argument in
        guard let refcon else { return }
        let context = Unmanaged<PowerContext>.fromOpaque(refcon).takeUnretainedValue()
        switch messageType {
        case PowerMessage.canSystemSleep, PowerMessage.systemWillSleep:
            if messageType == PowerMessage.systemWillSleep {
                Task { await PowerState.shared.recordSleep() }
            }
            /** Sleep is never vetoed; failing to acknowledge stalls the system. */
            IOAllowPowerChange(context.rootPort, Int(bitPattern: argument))
        case PowerMessage.systemHasPoweredOn:
            Task { await PowerState.shared.recordWake() }
        default:
            break
        }
    },
    &powerNotifier)
if powerContext.rootPort == 0 {
    FileHandle.standardError.write(
        Data("devctld: IORegisterForSystemPower failed; sleep/wake probes are unaware\n".utf8))
} else if let powerPort {
    IONotificationPortSetDispatchQueue(powerPort, DispatchQueue.main)
}

let server: ControlServer
do {
    server = try ControlServer(router: router, socketPath: paths.socketPath)
} catch {
    FileHandle.standardError.write(Data("devctld: cannot bind \(paths.socketPath): \(error)\n".utf8))
    exit(1)
}

/** Graceful termination: drain-stop every supervised server through the normal
    teardown path, unregister power notifications, then exit 0 (a deliberate
    stop must not trigger KeepAlive). */
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
terminationSource.setEventHandler {
    Task { @MainActor in
        await router.drainAll()
        if let port = powerPort {
            IONotificationPortSetDispatchQueue(port, nil)
        }
        if powerNotifier != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            powerNotifier = 0
        }
        if powerContext.rootPort != 0 {
            IOServiceClose(powerContext.rootPort)
            powerContext.rootPort = 0
        }
        if let port = powerPort {
            IONotificationPortDestroy(port)
            powerPort = nil
        }
        exit(0)
    }
}
terminationSource.resume()

/** Finish boot restore before accepting clients so install/restart re-ensure
    cannot race a half-finished restore. */
Task {
    await router.recoverAtStartup()
    /** Announced from the listener's ready state, so the line means a client can
        connect now rather than that start was called. */
    let socketPath = paths.socketPath
    server.start {
        FileHandle.standardError.write(
            Data(
                "devctld \(DevCtlVersion.version) listening on \(socketPath) (pid \(getpid()))\n"
                    .utf8))
    }
}

dispatchMain()
