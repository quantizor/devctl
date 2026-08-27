import Foundation

/** Pure labeling for Spotlight (and anything else that needs the same words).
    Titles lead with the project / head a person types so Spotlight's prefix
    ranking works; `devctl` lives in the subtitle so the rows stay branded
    without burying the match. */
public enum SpotlightLabel {
    /** Human title shown in Spotlight. Server name is omitted when it equals
        the project leaf (the common `myproj`/`myproj` case). */
    public static func title(project: String, server: String, head: String?) -> String {
        if let head {
            return "\(project) · \(head)"
        }
        if server == project {
            return project
        }
        return "\(project) · \(server)"
    }

    /** Subtitle: brand first, then the URL. */
    public static func subtitle(url: String) -> String {
        "devctl · \(url)"
    }

    /** Alternate titles Spotlight can match against without stuffing keywords.
        Host leaf and head name are the tokens people type after the project;
        `family` is the main checkout's slug for a worktree entry. */
    public static func alternateNames(
        project: String, server: String, head: String?, url: String, family: String? = nil
    ) -> [String] {
        var names: Set<String> = [project, server]
        if let head { names.insert(head) }
        if let family { names.insert(family) }
        if let host = URL(string: url)?.host {
            let leaf = host.split(separator: ".").first.map(String.init)
            if let leaf, !leaf.isEmpty, leaf != "localhost" {
                names.insert(leaf)
            }
        }
        names.remove(title(project: project, server: server, head: head))
        return names.sorted()
    }

    /** Relative importance among our own indexed items (0…100). Live and pinned
        surfaces win within the app; this cannot outrank filesystem Top Hits. */
    public static func rankingHint(phase: ServerPhase, pinned: Bool) -> Int {
        if pinned { return 100 }
        switch phase {
        case .running, .unhealthy: return 100
        case .starting, .stopping: return 95
        case .crashed, .failed, .stopped: return 90
        }
    }

    /** Keyword tokens: project, server, head, the main checkout's slug for a
        worktree entry, distinctive host/path parts, plus the standing "devctl"
        / "dev server" anchors so a typed "devctl myproj" still lands. */
    public static func keywords(
        project: String, server: String, head: String?, url: String, family: String? = nil
    ) -> [String] {
        var tokens: Set<String> = ["devctl", "dev server"]
        tokens.insert(project)
        tokens.insert(server)
        if let head { tokens.insert(head) }
        if let family { tokens.insert(family) }
        if let parsed = URL(string: url) {
            if let host = parsed.host {
                for part in host.split(separator: ".") where part != "localhost" && !part.isEmpty {
                    tokens.insert(String(part))
                }
            }
            for part in parsed.path.split(separator: "/") where !part.isEmpty {
                tokens.insert(String(part))
            }
        }
        return tokens.sorted()
    }
}
