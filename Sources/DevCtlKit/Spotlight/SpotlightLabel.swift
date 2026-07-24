import Foundation

/** Pure labeling for Spotlight (and anything else that needs the same words).
    Titles lead with the project / head a person types so Spotlight's prefix
    ranking works; `devctl` lives in the subtitle so the rows stay branded
    without burying the match. */
public enum SpotlightLabel {
    /** Human title shown in Spotlight. Server name is omitted when it equals
        the project leaf (the common `candor`/`candor` case). */
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

    /** Keyword tokens: project, server, head, distinctive host/path parts, plus
        the standing "devctl" / "dev server" anchors so a typed "devctl candor"
        still lands. */
    public static func keywords(project: String, server: String, head: String?, url: String)
        -> [String]
    {
        var tokens: Set<String> = ["devctl", "dev server"]
        tokens.insert(project)
        tokens.insert(server)
        if let head { tokens.insert(head) }
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
