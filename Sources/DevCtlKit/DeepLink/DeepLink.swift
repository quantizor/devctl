import Foundation

/** The action a `devctl://` URL requests. The raw value IS the URL authority
    (`devctl://<verb>/…`), so parsing and serializing round-trip through it. */
public enum DeepLinkVerb: String, Sendable, Equatable, CaseIterable, Codable {
    case ensure
    case open
    case stop
    case why
}

/** A parsed `devctl://` deep link. `head` is meaningful only for `open` (which
    surface of a multi-headed server to open); the parser rejects it on any other
    verb, so a `DeepLink` value is always internally consistent. */
public struct DeepLink: Sendable, Equatable, Codable {
    public var head: String?
    public var projectSlug: String
    public var server: String
    public var verb: DeepLinkVerb

    public init(verb: DeepLinkVerb, projectSlug: String, server: String, head: String? = nil) {
        self.head = head
        self.projectSlug = projectSlug
        self.server = server
        self.verb = verb
    }

    // MARK: - Parsing

    public static func parse(_ string: String) -> Result<DeepLink, WireError> {
        guard let components = URLComponents(string: string) else {
            return .failure(malformed(string))
        }
        return parse(components: components)
    }

    public static func parse(url: URL) -> Result<DeepLink, WireError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(malformed(url.absoluteString))
        }
        return parse(components: components)
    }

    private static func parse(components: URLComponents) -> Result<DeepLink, WireError> {
        guard components.scheme?.lowercased() == scheme else {
            return .failure(
                WireError(
                    code: .usage,
                    hint: "use a devctl://<verb>/<project>/<server> URL",
                    message: "not a devctl:// URL (scheme was '\(components.scheme ?? "")')"))
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(
                WireError(
                    code: .usage,
                    hint: "expected devctl://open/<project>/<server>",
                    message: "devctl:// URL is missing its verb"))
        }
        guard let verb = DeepLinkVerb(rawValue: host.lowercased()) else {
            return .failure(
                WireError(
                    code: .usage,
                    hint: "verbs are: \(DeepLinkVerb.allCases.map(\.rawValue).sorted().joined(separator: ", "))",
                    message: "unknown devctl verb '\(host)'"))
        }

        let segments = (components.percentEncodedPath)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }

        let slug: String
        let server: String
        var head: String?
        if segments.isEmpty {
            // Query-form alias: devctl://<verb>?project=&server=&head=
            let items = components.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }
            guard let project = value("project"), let name = value("server") else {
                return .failure(missingSegments(verb: verb))
            }
            slug = project
            server = name
            head = value("head")
        } else {
            guard segments.count >= 2 else {
                return .failure(missingSegments(verb: verb))
            }
            guard segments.count <= 3 else {
                return .failure(
                    WireError(
                        code: .usage,
                        hint: "shape is devctl://\(verb.rawValue)/<project>/<server>[/<head>]",
                        message: "too many path segments in devctl:// URL"))
            }
            slug = segments[0]
            server = segments[1]
            head = segments.count == 3 ? segments[2] : nil
        }

        // An empty head string (query alias `head=`) means "no head".
        if head?.isEmpty == true { head = nil }

        if let slugError = validateSlug(slug) {
            return .failure(slugError)
        }
        guard !server.isEmpty else {
            return .failure(
                WireError(code: .usage, message: "devctl:// URL has an empty server name"))
        }
        if head != nil, verb != .open {
            return .failure(
                WireError(
                    code: .usage,
                    hint: "only devctl://open/… takes a head",
                    message: "verb '\(verb.rawValue)' does not take a head"))
        }

        return .success(DeepLink(verb: verb, projectSlug: slug, server: server, head: head))
    }

    // MARK: - Serialization

    /** The canonical path-form URL string. Round-trips: parsing the result yields
        an equal `DeepLink`. */
    public func urlString() -> String {
        var parts = [projectSlug, server]
        if let head, verb == .open { parts.append(head) }
        let path = parts.map(Self.encodeSegment).joined(separator: "/")
        return "\(Self.scheme)://\(verb.rawValue)/\(path)"
    }

    // MARK: - Project resolution

    /** Maps a project slug to a concrete project path from a candidate list
        (each candidate is an absolute project directory). Matches the directory's
        last path component case-insensitively: a unique hit resolves, several hits
        are ambiguous (`usage`, candidates named), none is `not-found`. */
    public static func resolveProject(
        slug: String, against paths: [String]
    ) -> Result<String, WireError> {
        if let slugError = validateSlug(slug) {
            return .failure(slugError)
        }
        let wanted = slug.lowercased()
        var matches: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let base = (path as NSString).lastPathComponent.lowercased()
            if base == wanted, seen.insert(path).inserted {
                matches.append(path)
            }
        }
        switch matches.count {
        case 0:
            return .failure(
                WireError(
                    code: .notFound,
                    hint: "run: devctl status --all --json",
                    message: "no registered project matches '\(slug)'"))
        case 1:
            return .success(matches[0])
        default:
            /** Prefer the main checkout when a worktree shares the basename. */
            let mains = matches.filter { !CheckoutIdentity.isLinkedWorktree(project: $0) }
            if mains.count == 1 {
                return .success(mains[0])
            }
            let candidates = matches.sorted().joined(separator: ", ")
            return .failure(
                WireError(
                    code: .usage,
                    hint: "several projects share that name; open by full path",
                    message: "project slug '\(slug)' is ambiguous: \(candidates)"))
        }
    }

    // MARK: - Internals

    static let scheme = "devctl"

    private static func validateSlug(_ slug: String) -> WireError? {
        if slug.isEmpty {
            return WireError(code: .usage, message: "devctl:// URL has an empty project slug")
        }
        if slug.contains("/") || slug.contains("..") {
            return WireError(
                code: .usage,
                hint: "a project slug is a single directory name",
                message: "invalid project slug '\(slug)' (path separators and '..' are not allowed)")
        }
        return nil
    }

    private static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    /** URL path-segment characters minus `/`, so an encoded segment never splits. */
    private static let segmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    private static func malformed(_ raw: String) -> WireError {
        WireError(code: .usage, message: "could not parse a URL from '\(raw)'")
    }

    private static func missingSegments(verb: DeepLinkVerb) -> WireError {
        WireError(
            code: .usage,
            hint: "shape is devctl://\(verb.rawValue)/<project>/<server>",
            message: "devctl:// URL is missing its project and/or server")
    }
}
