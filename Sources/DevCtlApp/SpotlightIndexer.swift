import AppKit
import CoreSpotlight
import DevCtlKit
import Foundation

/** Spotlight integration: every server and every head becomes a searchable item
    ("candor · operator" opens the surface). Titles lead with the project/head;
    `devctl` lives in the subtitle. Ranking above filesystem Top Hits is not
    something Core Spotlight can force; this is best-effort discovery, not a
    launcher. Raycast/Alfred + `devctl://` is the fast path. */
enum SpotlightIndexer {
    /** nonisolated: read inside the (nonisolated) index completion callback. */
    nonisolated static let domain = "devctl-servers"
    /** Donated on open so Siri / Spotlight can predict the surface; the type is
        opaque since continuation runs through CSSearchableItemActionType, not this. */
    static let activityType = "dev.quantizor.devctl.open-surface"
    private static let entriesKey = "spotlight entries"
    private static let signatureKey = "spotlight signature"
    /** nonisolated: written inside the (nonisolated) index completion callback. */
    nonisolated private static let statusKey = "spotlight last sync"

    private static let baseRankingHint = 90
    private static let pinnedRankingHint = 100

    struct SpotlightEntry: Codable, Sendable {
        let icon: String?
        let keywords: [String]
        let rankingHint: Int
        let title: String
        let url: String
    }

    private static var currentActivity: NSUserActivity?

    static func sync(projects: [DaemonModel.ProjectGroup]) {
        HeadPins.shared.reconcile(projects: projects)
        let pins = HeadPins.shared
        var entriesByIdentifier: [String: SpotlightEntry] = [:]
        var payload: [(identifier: String, entry: SpotlightEntry)] = []
        for project in projects {
            for server in project.servers {
                if let url = server.url {
                    let identifier = "\(project.path)::\(server.server)"
                    let entry = SpotlightEntry(
                        icon: server.icon,
                        keywords: SpotlightLabel.keywords(
                            project: project.name, server: server.server, head: nil, url: url),
                        rankingHint: baseRankingHint,
                        title: SpotlightLabel.title(
                            project: project.name, server: server.server, head: nil),
                        url: url)
                    entriesByIdentifier[identifier] = entry
                    payload.append((identifier, entry))
                }
                for (head, url) in server.heads ?? [:] {
                    let identifier = "\(project.path)::\(server.server)::\(head)"
                    let pinned = pins.isPinned(project: project.path, server: server.server, head: head)
                    let entry = SpotlightEntry(
                        icon: server.icon,
                        keywords: SpotlightLabel.keywords(
                            project: project.name, server: server.server, head: head, url: url),
                        rankingHint: pinned ? pinnedRankingHint : baseRankingHint,
                        title: SpotlightLabel.title(
                            project: project.name, server: server.server, head: head),
                        url: url)
                    entriesByIdentifier[identifier] = entry
                    payload.append((identifier, entry))
                }
            }
        }
        let signature = "v6-cs-only|" + payload.map {
            "\($0.identifier)#\($0.entry.title)#\($0.entry.url)#\($0.entry.icon ?? "")#\($0.entry.rankingHint)#\($0.entry.keywords.joined(separator: ","))"
        }.sorted().joined(separator: "|")
        guard signature != UserDefaults.standard.string(forKey: signatureKey) else { return }
        if let data = try? JSONEncoder().encode(entriesByIdentifier) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
        UserDefaults.standard.set(signature, forKey: signatureKey)
        let items = payload
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            let built = items.map { element -> CSSearchableItem in
                let item = CSSearchableItem(
                    uniqueIdentifier: element.identifier,
                    domainIdentifier: domain,
                    attributeSet: attributeSet(for: element.entry))
                item.expirationDate = .distantFuture
                return item
            }
            let count = built.count
            CSSearchableIndex.default().indexSearchableItems(built) { error in
                UserDefaults.standard.set(
                    error.map { "error: \($0.localizedDescription)" }
                        ?? "ok \(count) items \(JSONCoding.formatISO8601(Date()))",
                    forKey: statusKey)
            }
        }
    }

    static func noteOpened(identifier: String) {
        guard let entry = loadEntries()[identifier] else { return }
        let item = CSSearchableItem(
            uniqueIdentifier: identifier,
            domainIdentifier: domain,
            attributeSet: attributeSet(for: entry, lastUsed: Date()))
        item.isUpdate = true
        item.expirationDate = .distantFuture
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        donateActivity(identifier: identifier, entry: entry)
    }

    nonisolated private static func attributeSet(
        for entry: SpotlightEntry, lastUsed: Date? = nil
    ) -> CSSearchableItemAttributeSet {
        /** `.text` surfaces on macOS; `.url` often indexes "ok" but never appears. */
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.displayName = entry.title
        attributes.title = entry.title
        attributes.contentDescription = SpotlightLabel.subtitle(url: entry.url)
        attributes.textContent = "\(entry.title)\n\(SpotlightLabel.subtitle(url: entry.url))"
        attributes.containerDisplayName = "devctl"
        attributes.kind = "Dev Server"
        attributes.keywords = entry.keywords
        attributes.rankingHint = NSNumber(value: entry.rankingHint)
        attributes.thumbnailData = entry.icon.flatMap(Self.thumbnailPNG)
        attributes.url = URL(string: entry.url)
        if let lastUsed { attributes.lastUsedDate = lastUsed }
        return attributes
    }

    private static func donateActivity(identifier: String, entry: SpotlightEntry) {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = entry.title
        activity.keywords = Set(entry.keywords)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        activity.isEligibleForSearch = true
        activity.persistentIdentifier = identifier
        if let url = URL(string: entry.url) { activity.webpageURL = url }
        let attributes = attributeSet(for: entry, lastUsed: Date())
        attributes.relatedUniqueIdentifier = identifier
        activity.contentAttributeSet = attributes
        activity.becomeCurrent()
        currentActivity = activity
    }

    private static func loadEntries() -> [String: SpotlightEntry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
            let map = try? JSONDecoder().decode([String: SpotlightEntry].self, from: data)
        else { return [:] }
        return map
    }

    nonisolated static func thumbnailPNG(path: String) -> Data? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let side: CGFloat = 128
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func url(forIdentifier identifier: String) -> URL? {
        loadEntries()[identifier].flatMap { URL(string: $0.url) }
    }
}
