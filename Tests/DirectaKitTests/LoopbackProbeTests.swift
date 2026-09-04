import Darwin
import Foundation
import Testing

@testable import DirectaKit

/** The shared loopback probe behind the port-held pre-check and `doctor`. The
    old CLI copy connected only to 127.0.0.1, so a Vite 5+ server bound to `::1`
    read as a free port; these prove both families are seen and a closed port is
    not. */
@Suite struct LoopbackProbeTests {
    /** Closed exactly once: the suite runs many tests in one process, so closing
        an fd twice can shut one another thread was handed in between. */
    @Test func seesAnIPv4Listener() {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(sock, 4)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(LoopbackProbe.isListening(port: port))
        close(sock)

        /** The negative uses a port this test holds and never listens on, which
            is race-free by construction. Asserting that the released port above
            stays free would not be: `bind(0)` returns an ephemeral port, the
            range the kernel hands to outbound connections, so another socket in
            this process can take it between the close and the probe. Re-binding
            it is no better, because a closed listener leaves the port in
            TIME_WAIT and the bind then fails for a reason that says nothing
            about the probe. */
        let quiet = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(quiet) }
        var quietAddr = sockaddr_in()
        quietAddr.sin_family = sa_family_t(AF_INET)
        quietAddr.sin_port = 0
        quietAddr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &quietAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(quiet, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var quietBound = sockaddr_in()
        var quietLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &quietBound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(quiet, $0, &quietLen)
            }
        }
        #expect(!LoopbackProbe.isListening(port: Int(UInt16(bigEndian: quietBound.sin_port))))
    }

    @Test func seesAnIPv6OnlyListener() {
        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(sock) }
        var only: Int32 = 1
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        addr.sin6_addr = in6addr_loopback
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        listen(sock, 4)
        var bound = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: bound.sin6_port))
        #expect(LoopbackProbe.isListening(port: port))
    }

    /** A port outside a TCP port's range used to trap inside the probe, which
        under launchd KeepAlive is a crash loop: boot restore re-reads the config
        that caused it and dies again on every relaunch. Nothing can listen on a
        port that cannot exist, so the probe answers false. */
    @Test(arguments: [-1, 0, 65_536, 70_000, Int(Int32.max)])
    func anImpossiblePortIsNotListeningRatherThanATrap(port: Int) {
        #expect(!LoopbackProbe.isListening(port: port))
    }

    /** The commit that guarded the port left the value beside it unguarded, so
        `Int32(timeoutMs)` still trapped on a healthcheck `timeoutMs` a repo
        supplied. Returning from this test is the assertion: a trap would take
        the whole runner down rather than fail one case.

        The negative argument is the one that is not a trap and is worse for it:
        `poll` reads a negative deadline as wait-forever, so before the clamp
        this wedged the health task silently instead of reporting anything. It
        is bounded here by the port being closed, so the probe must answer
        promptly rather than block. */
    @Test(arguments: [-1, Int.min, Int.max, Int(Int32.max) + 1])
    func anImpossibleTimeoutAnswersRatherThanTrappingOrHanging(timeoutMs: Int) {
        /** Port 1 is privileged, so nothing on a developer machine is bound to
            it and the connect is refused with an immediate RST. That matters for
            the clock, not just the verdict: a port that is bound but NOT
            listening (which is how the test above builds its negative) gets no
            RST, so the IPv4 connect sits in SYN retransmit for about 7.8s and
            these four cases alone cost more than a quarter of the suite budget.
            Measured both ways before choosing. */
        #expect(!LoopbackProbe.isListening(port: 1, timeoutMs: timeoutMs))
    }
}
