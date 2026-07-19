import DevCtlKit
import Foundation

/** The rule-based diagnosis behind `devctl why`: turn the data the daemon
    already holds (phase, forensics, health, err-stream tails, the dependency
    graph) into a finding chain with a root-cause statement. */
enum WhyEngine {
    /** Diagnoses `target` and walks dependsOn to find the deepest broken
        dependency, which becomes the root cause. */
    static func diagnose(
        target: String,
        statuses: [String: ServerStatus],
        specs: [String: ServerSpec],
        errTail: (String) -> [String]
    ) -> WhyResult {
        var findings: [WhyFinding] = []
        var visited = Set<String>()
        var rootCause: String?
        var frontier = [target]
        while let name = frontier.popLast() {
            guard visited.insert(name).inserted, let status = statuses[name] else { continue }
            let finding = describe(status: status, errTail: errTail)
            findings.append(finding)
            let broken = status.phase != .running && status.phase != .stopped
            if broken || status.phase == .stopped {
                /** A broken or stopped dependency deeper in the chain supersedes
                    the target's own symptom as root cause. */
                if name != target || rootCause == nil {
                    rootCause = "\(name): \(finding.summary)"
                }
            }
            for dep in specs[name]?.dependsOn ?? [] {
                frontier.append(dep)
            }
        }
        /** The walk visits target first; if a dependency was broken it overwrote
            rootCause last, which is exactly the deepest-cause preference. */
        return WhyResult(findings: findings, rootCause: rootCause)
    }

    private static func describe(status: ServerStatus, errTail: (String) -> [String]) -> WhyFinding {
        var evidence: [String] = []
        var summary: String
        switch status.phase {
        case .failed:
            summary = "spawn never succeeded: \(status.spawnError?.message ?? "unknown spawn error")"
            evidence.append("log: \(status.logPath)")
        case .crashed:
            let cause = status.lastExit?.code.map { "exit \($0)" }
                ?? status.lastExit?.signal.map { "signal \($0)" } ?? "unknown cause"
            let when = status.lastExit.map { JSONCoding.formatISO8601($0.at) } ?? "unknown time"
            summary = "crashed (\(cause)) at \(when)"
            evidence.append(contentsOf: errTail(status.server).map { "err: \($0)" })
        case .unhealthy:
            let since = status.lastHealthAt.map { JSONCoding.formatISO8601($0) } ?? "startup"
            summary = "healthcheck failing; last healthy \(since)"
            evidence.append(contentsOf: errTail(status.server).map { "err: \($0)" })
        case .starting:
            summary = "still starting; healthcheck (\(status.healthcheck.rawValue)) has not passed yet"
        case .stopped:
            summary = "not running (stopped)"
        case .stopping:
            summary = "shutting down"
        case .running:
            summary = "running and healthy"
        }
        if let declared = status.declaredPort, let observed = status.observedPort, declared != observed {
            summary += "; NOTE: listening on \(observed), not the declared \(declared)"
            evidence.append("declared port \(declared), observed \(observed)")
        }
        if status.specStale == true {
            evidence.append("config changed since this process started (restart to apply)")
        }
        return WhyFinding(
            evidence: evidence, phase: status.phase, server: status.server, summary: summary)
    }
}
