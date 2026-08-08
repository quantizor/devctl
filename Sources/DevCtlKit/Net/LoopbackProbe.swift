import Darwin
import Foundation

/** Is anything accepting connections on a loopback port right now.

    Lives in DevCtlKit because two callers need it and cannot share a home
    otherwise: the daemon's health prober and the CLI's `doctor`, which cannot
    import DevCtlDaemonCore (that target links swift-subprocess). The CLI used to
    carry its own IPv4-only copy with a blocking connect and no deadline, which
    reported a free port for anything bound to `::1` alone. */
public enum LoopbackProbe {
    /** Dev servers bind either stack: Vite 5+ listens on `::1` only, older
        tooling on `127.0.0.1` only, so both loopback families are tried and
        either answering counts as a live listener. */
    public static func isListening(port: Int, timeoutMs: Int = 300) -> Bool {
        connects(port: port, timeoutMs: timeoutMs, family: AF_INET)
            || connects(port: port, timeoutMs: timeoutMs, family: AF_INET6)
    }

    /** Non-blocking connect with a poll deadline, so an unreachable port cannot
        stall a status call for the kernel's full connect timeout. */
    private static func connects(port: Int, timeoutMs: Int, family: Int32) -> Bool {
        /** A port arrives from a repo's devservers.json, from `--port`, and from
            portSpan arithmetic that can run off the end of the range, and
            `UInt16(port)` traps on anything outside 0...65535. Under launchd
            KeepAlive that trap is a crash loop: boot restore re-reads the same
            config and dies again on every relaunch. Nothing can be listening on
            a port that does not exist, so answer that instead of trapping. */
        guard let narrowed = UInt16(exactly: port), narrowed > 0 else { return false }
        let sock = socket(family, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        let flags = fcntl(sock, F_GETFL)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        var storage = sockaddr_storage()
        let sockLen: socklen_t
        if family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = narrowed.bigEndian
            addr.sin6_addr = in6addr_loopback
            sockLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = addr }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = narrowed.bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            sockLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee = addr }
            }
        }
        let result = withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, sockLen)
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollTarget = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollTarget, 1, Int32(timeoutMs)) == 1 else { return false }
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        return soError == 0
    }
}
