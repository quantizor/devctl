import AppKit
import CoreSpotlight
import DevCtlKit
import Foundation

/** Spotlight integration: every server and every head becomes a searchable item
    ("candor operator" from anywhere opens the surface in the browser). The
    id -> URL map is persisted at index time so activation resolves without the
    daemon on the hot path. Re-indexes only when the item set changes. */
enum SpotlightIndexer {
    static let domain = "devctl-servers"
    private static let urlMapKey = "spotlight urls"
    private static let signatureKey = "spotlight signature"
    private static let statusKey = "spotlight last sync"

    static func sync(projects: [DaemonModel.ProjectGroup]) {
        var urlByIdentifier: [String: String] = [:]
        var entriesToIndex: [(icon: String?, identifier: String, title: String, url: String)] = []
        for project in projects {
            for server in project.servers {
                var entries: [(icon: String?, identifier: String, title: String, url: String)] = []
                if let url = server.url {
                    entries.append(
                        (
                            icon: server.icon,
                            identifier: "\(project.path)::\(server.server)",
                            title: "\(project.name) \(server.server)",
                            url: url
                        ))
                }
                for (head, url) in server.heads ?? [:] {
                    entries.append(
                        (
                            icon: server.icon,
                            identifier: "\(project.path)::\(server.server)::\(head)",
                            title: "\(project.name) \(head)",
                            url: url
                        ))
                }
                for entry in entries {
                    urlByIdentifier[entry.identifier] = entry.url
                    entriesToIndex.append(entry)
                }
            }
        }
        let signature = urlByIdentifier.keys.sorted().joined(separator: "|")
            + "#" + urlByIdentifier.values.sorted().joined(separator: "|")
            + "#" + entriesToIndex.compactMap(\.icon).sorted().joined(separator: "|")
        guard signature != UserDefaults.standard.string(forKey: signatureKey) else { return }
        UserDefaults.standard.set(urlByIdentifier, forKey: urlMapKey)
        UserDefaults.standard.set(signature, forKey: signatureKey)
        /** CSSearchableItem is not Sendable, so the items are BUILT inside the
            callback from Sendable value tuples rather than captured across it. */
        let payload = entriesToIndex
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            let items = payload.map { entry -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .url)
                attributes.contentDescription = "\(entry.url) · devctl dev server"
                attributes.keywords = ["devctl", "dev server"]
                attributes.thumbnailData = entry.icon.flatMap(Self.thumbnailPNG)
                attributes.title = entry.title
                attributes.url = URL(string: entry.url)
                let item = CSSearchableItem(
                    uniqueIdentifier: entry.identifier,
                    domainIdentifier: domain,
                    attributeSet: attributes)
                item.expirationDate = .distantFuture
                return item
            }
            let count = items.count
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                UserDefaults.standard.set(
                    error.map { "error: \($0.localizedDescription)" }
                        ?? "ok \(count) items \(JSONCoding.formatISO8601(Date()))",
                    forKey: statusKey)
            }
        }
    }

    /** Rasterizes a config-supplied icon (png/svg/pdf, anything NSImage reads)
        to PNG at thumbnail size. */
    /** nonisolated: runs inside the index callback; offscreen NSImage drawing
        has no main-thread dependence. */
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

    /** Resolves a Spotlight activation to its URL via the persisted map. */
    static func url(forIdentifier identifier: String) -> URL? {
        let map = UserDefaults.standard.dictionary(forKey: urlMapKey) as? [String: String]
        return map?[identifier].flatMap(URL.init(string:))
    }
}
