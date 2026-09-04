import Foundation

/** Cross-project port collisions, found from declared ports alone so the report
    stands whether or not anything is running.

    Lives in DirectaKit because `doctor` is the caller and the CLI cannot import
    DirectaDaemonCore. The daemon's own refusal path answers the same question at
    start time; this answers it before anyone tries to start. */
public enum PortCollision {
    /** Two servers in unrelated projects that declare one port. */
    public struct Pair: Equatable, Sendable {
        public let first: String
        public let port: Int
        public let second: String

        public init(first: String, port: Int, second: String) {
            self.first = first
            self.port = port
            self.second = second
        }

        /** Reads as the doctor finding it becomes. */
        public var detail: String {
            "port \(port) is declared by both \(first) and \(second); only one can bind, so change one or run them one at a time"
        }
    }

    /** Servers that declare the same port cannot both bind, whatever hostnames
        they advertise: every `*.localhost` name resolves to loopback, so the host
        does not disambiguate a bind. A host-keyed check misses this entirely.

        Two exclusions, both deliberate:
        - Same project: the host matches too, so the existing signature check
          already reports it and a second finding would be noise.
        - Sibling worktrees: linked checkouts share a committed port on purpose
          and rebind on ensure, so a collision there is the design working. */
    public static func detect(_ servers: [ServerStatus]) -> [Pair] {
        var byPort: [Int: [ServerStatus]] = [:]
        for server in servers {
            /** Group on the port that actually binds. `declaredPort` is the
                committed value before an override or a sibling rebind, so two
                projects can share it while binding different ports, and two
                projects with different committed ports can be overridden onto
                one. Keying on the committed value gets both cases wrong. */
            guard let port = server.effectivePort ?? server.declaredPort else { continue }
            byPort[port, default: []].append(server)
        }
        var pairs: [Pair] = []
        for (port, group) in byPort {
            let ordered = group.sorted { label($0) < label($1) }
            var distinct: [ServerStatus] = []
            for candidate in ordered {
                let related = distinct.contains {
                    $0.project == candidate.project
                        || CheckoutIdentity.shareCommonDir($0.project, candidate.project)
                }
                if related { continue }
                distinct.append(candidate)
            }
            guard let owner = distinct.first, distinct.count > 1 else { continue }
            for other in distinct.dropFirst() {
                pairs.append(Pair(first: label(owner), port: port, second: label(other)))
            }
        }
        return pairs.sorted { ($0.port, $0.second) < ($1.port, $1.second) }
    }

    private static func label(_ server: ServerStatus) -> String {
        "\(server.server) (\(server.project))"
    }
}
