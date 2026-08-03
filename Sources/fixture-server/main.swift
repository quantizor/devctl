import Foundation

/** fixture-server: the test double for a real dev server. Modes compose:
    --listen-tcp PORT      accept TCP connections (healthcheck target)
    --exit-after SECONDS   terminate itself after a delay
    --code N               exit code to use with --exit-after
    --spawn-grandchild     spawn a `sleep 1000` child (group-kill verification)
    --ignore-sigterm       install SIG_IGN for SIGTERM (escalation verification)
    --emit-binary          write raw non-UTF8 bytes into stdout once
    --err-lines N          write N lines to stderr at startup (error-tally fixture)
    --flood                write lines as fast as possible
    Default behavior: print a heartbeat line every 200ms. */

var listenPort: UInt16?
var exitAfter: Double?
var exitCode: Int32 = 0
var spawnGrandchild = false
var ignoreSigterm = false
var emitBinary = false
var errLines = 0
var flood = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--listen-tcp":
        listenPort = argIterator.next().flatMap { UInt16($0) }
    case "--exit-after":
        exitAfter = argIterator.next().flatMap { Double($0) }
    case "--code":
        exitCode = argIterator.next().flatMap { Int32($0) } ?? 0
    case "--spawn-grandchild":
        spawnGrandchild = true
    case "--ignore-sigterm":
        ignoreSigterm = true
    case "--emit-binary":
        emitBinary = true
    case "--err-lines":
        errLines = argIterator.next().flatMap { Int($0) } ?? 0
    case "--flood":
        flood = true
    default:
        FileHandle.standardError.write(Data("fixture-server: unknown argument \(arg)\n".utf8))
        exit(2)
    }
}

setbuf(stdout, nil)

if ignoreSigterm {
    signal(SIGTERM, SIG_IGN)
}

if spawnGrandchild {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["1000"]
    try? child.run()
    print("grandchild pid \(child.processIdentifier)")
}

if emitBinary {
    let junk: [UInt8] = [0xFF, 0xFE, 0x00, 0x80, 0x0A]
    FileHandle.standardOutput.write(Data(junk))
}

/** A distinctive token so a test can assert the raw child bytes never leak into
    the agent context block, while its count is still surfaced. */
for index in 0..<errLines {
    FileHandle.standardError.write(Data("FIXTURE-ERR-TOKEN line \(index)\n".utf8))
}

if let listenPort {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = listenPort.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(sock, 16) == 0 else {
        FileHandle.standardError.write(Data("fixture-server: cannot listen on \(listenPort)\n".utf8))
        exit(1)
    }
    print("listening on \(listenPort)")
    Thread {
        while true {
            let client = accept(sock, nil, nil)
            if client < 0 { continue }
            let banner = "hello from fixture-server\n"
            _ = banner.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }.start()
}

if let exitAfter {
    /** Captured here rather than read inside the closure: a top-level `var` is
        main-actor isolated, and the dispatch closure is not. Argument parsing is
        already done, so the value cannot change after this point. */
    let code = exitCode
    DispatchQueue.global().asyncAfter(deadline: .now() + exitAfter) {
        print("exiting with code \(code)")
        exit(code)
    }
}

var heartbeat = 0
while true {
    heartbeat += 1
    print("heartbeat \(heartbeat)")
    if !flood {
        usleep(200_000)
    }
}
