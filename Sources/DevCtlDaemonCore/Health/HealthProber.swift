import DevCtlKit
import Foundation

/** The resolved healthcheck a server actually runs: explicit config wins, a
    declared port implies a TCP probe, and nothing at all means "alive past a
    stabilization window". */
public enum EffectiveHealthcheck: Equatable, Sendable {
    case http(url: String, timeoutMs: Int)
    case none(stabilizationMs: Int)
    case tcp(port: Int, timeoutMs: Int)

    public static func resolve(spec: ServerSpec) -> EffectiveHealthcheck {
        let timeoutMs = spec.healthcheck?.timeoutMs ?? 1500
        switch spec.healthcheck?.type {
        case .http:
            if let url = spec.healthcheck?.url {
                return .http(url: url, timeoutMs: timeoutMs)
            }
        case .tcp:
            if let port = spec.healthcheck?.port ?? spec.port {
                return .tcp(port: port, timeoutMs: timeoutMs)
            }
        case .none?:
            return .none(stabilizationMs: 2000)
        case nil:
            break
        }
        if let port = spec.port {
            return .tcp(port: port, timeoutMs: timeoutMs)
        }
        return .none(stabilizationMs: 2000)
    }

    public var kind: HealthCheckType {
        switch self {
        case .http: .http
        case .none: .none
        case .tcp: .tcp
        }
    }
}

/** Seam for tests: the supervisor's health loop asks this, and unit tests inject
    a scripted prober instead of a real network. */
public protocol HealthProber: Sendable {
    func probe(_ check: EffectiveHealthcheck) async -> Bool
}

public struct NetworkHealthProber: HealthProber {
    /** Dedicated ephemeral session so probes do not share URLSession.shared
        caches or the default 60s resource timeout. */
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RedirectStopper.shared, delegateQueue: nil)
    }()

    public init() {}

    public func probe(_ check: EffectiveHealthcheck) async -> Bool {
        switch check {
        case .none:
            /** Stabilization timing lives in the monitor loop; the probe itself
                only answers "is the process still the thing we care about", which
                the supervisor already knows. */
            return true
        case .http(let url, let timeoutMs):
            guard let parsed = URL(string: url) else { return false }
            var request = URLRequest(url: parsed)
            request.timeoutInterval = Double(timeoutMs) / 1000
            /** *.localhost hosts resolve in browsers but not reliably in the
                system resolver; probe loopback directly and carry the Host header
                so vhost-aware dev servers still route. The bind stack is not
                knowable ahead (Vite 5+ binds `::1` only), so IPv6 loopback is
                retried when IPv4 refuses. */
            let originalHost = parsed.host
            if let host = originalHost, host != "127.0.0.1", host != "localhost",
                host.hasSuffix(".localhost"), var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) {
                components.host = "127.0.0.1"
                if let rewritten = components.url {
                    request.url = rewritten
                    request.setValue(host, forHTTPHeaderField: "Host")
                }
            }
            do {
                return try await Self.httpResponds(request)
            } catch {
                /** IPv4 failed; retry over IPv6 loopback carrying the same Host. */
                guard let host = originalHost, host.hasSuffix(".localhost"),
                    var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
                else { return false }
                components.host = "[::1]"
                guard let rewritten = components.url else { return false }
                var v6 = URLRequest(url: rewritten)
                v6.timeoutInterval = request.timeoutInterval
                v6.setValue(host, forHTTPHeaderField: "Host")
                return (try? await Self.httpResponds(v6)) ?? false
            }
        case .tcp(let port, let timeoutMs):
            return Self.tcpConnects(port: port, timeoutMs: timeoutMs)
        }
    }

    /** A 3xx IS a healthy answer (login redirects abound in dev apps);
        following it would re-enter hostname resolution the loopback rewrite
        just avoided, so redirects never get followed. */
    private static func httpResponds(_ request: URLRequest) async throws -> Bool {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    /** Refuses redirect-following so the probe judges the first response. */
    final class RedirectStopper: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectStopper()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /** Non-blocking connect to a loopback port with a poll deadline. Dev
        servers bind either stack: Vite 5+ listens on `::1` only, older
        tooling on `127.0.0.1` only, so both loopback families are tried and
        either answering counts as healthy. */
    static func tcpConnects(port: Int, timeoutMs: Int) -> Bool {
        tcpConnects(port: port, timeoutMs: timeoutMs, family: AF_INET)
            || tcpConnects(port: port, timeoutMs: timeoutMs, family: AF_INET6)
    }

    private static func tcpConnects(port: Int, timeoutMs: Int, family: Int32) -> Bool {
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
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = in6addr_loopback
            sockLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = addr }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
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

/** Port ownership diagnostics: best-effort lsof shell-outs. These inform errors
    and status; supervision never depends on them. */
public enum PortGuard {
    /** True when something accepts on 127.0.0.1:port right now. */
    public static func isListening(port: Int) -> Bool {
        NetworkHealthProber.tcpConnects(port: port, timeoutMs: 300)
    }

    /** The pid + command listening on a port, when lsof can name it. */
    public static func listenerInfo(port: Int) -> (pid: Int, command: String)? {
        guard let output = shell("/usr/sbin/lsof", ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]),
            let pid = Int(output.split(separator: "\n").first ?? "")
        else { return nil }
        let command = shell("/bin/ps", ["-o", "command=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return (pid: pid, command: command)
    }

    /** TCP ports the given processes are listening on. */
    public static func listeningPorts(pids: [pid_t]) -> [Int] {
        guard !pids.isEmpty,
            let output = shell(
                "/usr/sbin/lsof",
                ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN"])
        else { return [] }
        var ports: [Int] = []
        for line in output.split(separator: "\n").dropFirst() {
            /** lsof NAME column ends in `:PORT (LISTEN)`. */
            guard let nameField = line.split(separator: " ").dropLast().last,
                let portText = nameField.split(separator: ":").last,
                let port = Int(portText)
            else { continue }
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
