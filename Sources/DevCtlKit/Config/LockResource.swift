import Foundation

/** Reading a resource's declarations across the servers of one project. Kept in
    one place so the pause loop, the lock gate, and the identity check cannot
    disagree about which servers declare a resource or where its state lives. */
public enum LockResource {
    public static func declares(resource: String, spec: ServerSpec) -> Bool {
        (spec.locks ?? []).contains { $0.name == resource }
    }

    public static func declarers(resource: String, specs: [ServerSpec]) -> [String] {
        specs.filter { declares(resource: resource, spec: $0) }.map(\.name).sorted()
    }

    /** The absolute state path declared for `resource`, or nil when no declarer
        names one. Throws when two declarers name different paths: devctl would
        have to guess which state it is guarding, and guessing is how the
        incident behind this check happened. */
    public static func statePath(project: String, resource: String, specs: [ServerSpec]) throws
        -> String?
    {
        var found: (path: String, server: String)?
        for spec in specs {
            for declaration in spec.locks ?? []
            where declaration.name == resource && declaration.path != nil {
                guard let relative = declaration.path else { continue }
                let absolute = URL(fileURLWithPath: project).appending(path: relative)
                    .standardizedFileURL.path
                if let existing = found, existing.path != absolute {
                    throw WireError(
                        code: .configInvalid,
                        hint: "run: devctl config check",
                        message:
                            "servers '\(existing.server)' and '\(spec.name)' declare resource '\(resource)' with different state paths (\(existing.path) and \(absolute)); devctl cannot tell which state a lock guards"
                    )
                }
                found = (path: absolute, server: spec.name)
            }
        }
        return found?.path
    }
}
