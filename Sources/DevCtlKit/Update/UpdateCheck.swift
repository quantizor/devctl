import Foundation

/** The result of an update check, computed against the running version so the
    same cache answers correctly whatever binary reads it. */
public struct UpdateStatus: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var currentVersion: String
    public var latestVersion: String
    public var updateAvailable: Bool

    public init(
        checkedAt: Date, currentVersion: String, latestVersion: String, updateAvailable: Bool
    ) {
        self.checkedAt = checkedAt
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
    }
}

/** Checks GitHub for a newer release, sharing one on-disk cache between the app
    (which polls) and `devctl doctor` (which reads the cache and refreshes only
    when stale). Every failure is silent: an update notice is a convenience, never
    something worth interrupting a session or a command for. The result never
    enters `AgentContext.render`; a version notice in every session start is noise
    and the hook's output is meant for the servers, not devctl itself. */
public enum UpdateCheck {
    /** How long a cached answer is trusted before a refresh. A multi-hour cadence
        sits far inside GitHub's unauthenticated 60-requests-per-hour budget, and
        the ETag below makes an unchanged check a cheap 304. */
    public static let defaultMaxAge: TimeInterval = 6 * 3600

    /** Cached network facts. The running version is deliberately not stored: it
        is applied at read time so an upgraded binary reading an old cache still
        computes the right answer. */
    struct Cache: Codable {
        var checkedAt: Date
        var etag: String?
        var latestVersion: String
    }

    static func cacheURL(paths: DevCtlPaths) -> URL {
        paths.dataDir.appending(path: "update-check.json")
    }

    /** The last cached answer, or nil when nothing has been checked yet. */
    public static func cachedStatus(
        paths: DevCtlPaths = DevCtlPaths(), currentVersion: String = DevCtlVersion.version
    ) -> UpdateStatus? {
        guard let cache = AtomicFile.loadDefensively(Cache.self, from: cacheURL(paths: paths))
        else { return nil }
        return status(from: cache, currentVersion: currentVersion)
    }

    static func status(from cache: Cache, currentVersion: String) -> UpdateStatus {
        UpdateStatus(
            checkedAt: cache.checkedAt,
            currentVersion: currentVersion,
            latestVersion: cache.latestVersion,
            updateAvailable:
                SetupPlanner.compareVersions(cache.latestVersion, currentVersion) == .orderedDescending
        )
    }

    /** Return the cached answer when it is younger than `maxAge`; otherwise
        fetch. Doctor uses this so a machine where the app never runs still gets an
        answer without the CLI hitting the network on every invocation. */
    public static func refreshIfStale(
        paths: DevCtlPaths = DevCtlPaths(), maxAge: TimeInterval = defaultMaxAge,
        currentVersion: String = DevCtlVersion.version, now: Date = Date()
    ) async -> UpdateStatus? {
        if let cache = AtomicFile.loadDefensively(Cache.self, from: cacheURL(paths: paths)),
            now.timeIntervalSince(cache.checkedAt) < maxAge
        {
            return status(from: cache, currentVersion: currentVersion)
        }
        return await refresh(paths: paths, currentVersion: currentVersion, now: now)
    }

    /** Fetch the newest non-prerelease and update the cache. Conditional on the
        stored ETag, so an unchanged release costs a 304. Any failure returns
        whatever was cached, silently. */
    @discardableResult
    public static func refresh(
        paths: DevCtlPaths = DevCtlPaths(), currentVersion: String = DevCtlVersion.version,
        now: Date = Date()
    ) async -> UpdateStatus? {
        let existing = AtomicFile.loadDefensively(Cache.self, from: cacheURL(paths: paths))
        func cachedFallback() -> UpdateStatus? {
            existing.map { status(from: $0, currentVersion: currentVersion) }
        }
        guard let url = URL(string: DevCtlDistribution.latestReleaseAPIURL) else {
            return cachedFallback()
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("devctl", forHTTPHeaderField: "User-Agent")
        if let etag = existing?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return cachedFallback() }
            if http.statusCode == 304, var cache = existing {
                cache.checkedAt = now
                persist(cache, paths: paths)
                return status(from: cache, currentVersion: currentVersion)
            }
            guard http.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = object["tag_name"] as? String
            else { return cachedFallback() }
            let cache = Cache(
                checkedAt: now,
                etag: (http.value(forHTTPHeaderField: "Etag")
                    ?? http.value(forHTTPHeaderField: "ETag")),
                latestVersion: normalize(tag))
            persist(cache, paths: paths)
            return status(from: cache, currentVersion: currentVersion)
        } catch {
            return cachedFallback()
        }
    }

    private static func persist(_ cache: Cache, paths: DevCtlPaths) {
        guard let data = try? JSONCoding.encoder().encode(cache) else { return }
        try? AtomicFile.write(data, to: cacheURL(paths: paths))
    }

    /** Tags are `vX.Y.Z`; the leading `v` is dropped so the string compares with
        the bare `DevCtlVersion.version`. */
    static func normalize(_ tag: String) -> String {
        var trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        return trimmed
    }
}
