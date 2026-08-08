import Darwin
import Foundation

/** The harness-agnostic session-context block: fenced plain text any agent
    harness can inject at session start (and after compaction) so a new or reset
    session relearns what devctl is running. Pure over an already-fetched status
    list, so it is unit-tested here; the socket fetch and the daemon guards live
    in the CLI.

    Every string this emits is devctl's own: a phase, a port, a count, a
    timestamp, a strerror name. A line of child output or a configured command
    string never appears, because both are attacker-influenceable and would reach
    an agent's context unattributed. Surfacing that an error stream is piling up
    is safe (the count and timestamps are arithmetic); surfacing the lines
    themselves is not, so the block points the agent at `devctl why`, which it
    runs itself and can attribute. */
public enum AgentContext {
    public static let maxLength = 2400

    /** Nil when there is nothing to say: an untrusted project (the hook advertises
        only trusted ones) or no registered servers. Otherwise the fenced block,
        truncated to `maxLength` with the closing tag preserved. */
    public static func render(list: ServerListResult) -> String? {
        guard list.trusted == true, !list.servers.isEmpty else { return nil }
        /** Bad-state servers lead: the block is length-capped and truncates from
            the end, so the servers an agent must act on cannot sit behind the
            healthy ones. Alphabetical within each group for a stable read. */
        let ordered = list.servers.sorted { lhs, rhs in
            let lb = isBadState(lhs), rb = isBadState(rhs)
            if lb != rb { return lb }
            return lhs.server < rhs.server
        }
        var lines: [String] = ["<devctl-servers>"]
        lines.append(
            "This project's dev servers are managed by devctl (daemon-supervised; they and their logs survive session compaction and restarts). Prefer devctl over launching servers directly.")
        if let project = ordered.first?.project, CheckoutIdentity.isLinkedWorktree(project: project) {
            let preferred = CheckoutIdentity.preferredSubdomain(project: project, committedHost: nil)
            lines.append(
                "This checkout is a git worktree of \(preferred); use the URLs below, not the main checkout's host.")
        }
        for server in ordered {
            lines.append(bullet(for: server))
            if let conflict = server.portConflict {
                lines.append("  warning: \(conflict.message)")
            }
            if isBadState(server) {
                if let summary = server.errorSummary {
                    lines.append("  \(errorLine(summary))")
                }
                lines.append("  run: devctl why \(server.server) --json")
            }
        }
        lines.append(
            "Useful: devctl ensure <name> (idempotent start) · devctl wait <name> --healthy · devctl why <name> (root cause) · devctl logs <name> --since-mark <id> --json · devctl mark <name> \"text\" · devctl events --since 10m · devctl lock <resource> -- … (exclusive access to a resource a server holds; prefer it over stopping the server). All support --json.")
        /** The invitation and its constraint stay on one line: render truncates
            from the end and re-appends only the closing fence, so a clause on its
            own line can be cut while the invitation above it survives. That
            already produced one report naming a private project. */
        lines.append(
            "While you work, monitor devctl itself: if it misbehaves, surprises you, or a missing capability slows you down, flag it (a line in ~/code/devctl/BACKLOG.md, or tell the user) rather than silently working around it. Report devctl's behavior and how to reproduce it generically, never this project's name, paths, hosts, ports, or log lines: that file lives outside this project.")
        lines.append("</devctl-servers>")
        let text = lines.joined(separator: "\n")
        return text.count > maxLength ? String(text.prefix(maxLength)) + "\n</devctl-servers>" : text
    }

    /** A server that warrants attention: broken outright, degraded, or running
        against a spec that has since changed on disk. */
    private static func isBadState(_ server: ServerStatus) -> Bool {
        switch server.phase {
        case .crashed, .failed, .unhealthy:
            return true
        case .running, .starting, .stopped, .stopping:
            return server.specStale == true || conflictWarrantsAttention(server.portConflict?.state)
        }
    }

    /** Exhaustive on purpose: a new conflict state has to be classified here
        rather than defaulting to silence, which is how a conflict reaches an
        agent's session context at all. */
    private static func conflictWarrantsAttention(_ state: PortConflictState?) -> Bool {
        switch state {
        case .drift, .foreign, .held, .shared:
            return true
        case .rebound, .none:
            /** Rebound is the sibling-worktree path working as designed. */
            return false
        }
    }

    private static func bullet(for server: ServerStatus) -> String {
        var parts = ["- \(server.server): \(server.phase.rawValue)"]
        if let url = server.url { parts.append(url) }
        if let heads = server.heads, !heads.isEmpty {
            let rendered = heads.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            parts.append("heads: \(rendered)")
        }
        if let port = server.effectivePort ?? server.observedPort ?? server.declaredPort {
            parts.append("port \(port)")
        }
        if let ports = server.ports, !ports.isEmpty {
            let rendered = ports.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            parts.append("ports: \(rendered)")
        }
        if let conflict = server.portConflict, conflict.state == .rebound {
            parts.append("rebinding: worktree checkout, not the main origin")
        }
        switch server.phase {
        case .crashed:
            if let exit = server.lastExit {
                let cause = exit.code.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "unknown"
                parts.append("last exit \(cause) at \(JSONCoding.formatISO8601(exit.at))")
            }
        case .failed:
            /** strerror is devctl's own naming of the OS error, never the
                spawnError message, which can echo the configured command. */
            parts.append("spawn failed: \(spawnCause(server.spawnError))")
        case .unhealthy:
            let since = server.lastHealthAt.map { JSONCoding.formatISO8601($0) } ?? "startup"
            parts.append("last healthy \(since)")
        case .running, .starting, .stopped, .stopping:
            break
        }
        if server.specStale == true { parts.append("config changed since start") }
        parts.append("log \(server.logPath)")
        return parts.joined(separator: " · ")
    }

    private static func spawnCause(_ error: SpawnError?) -> String {
        guard let errno = error?.errno, errno != 0 else { return "could not start" }
        return String(cString: strerror(Int32(errno)))
    }

    private static func errorLine(_ summary: ErrorSummary) -> String {
        if summary.count == 1 {
            return "1 error line at \(JSONCoding.formatISO8601(summary.lastAt))"
        }
        return "\(summary.count) error lines since \(JSONCoding.formatISO8601(summary.firstAt)), latest \(JSONCoding.formatISO8601(summary.lastAt))"
    }
}
