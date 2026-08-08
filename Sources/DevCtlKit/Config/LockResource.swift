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
        let root = URL(fileURLWithPath: project).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for spec in specs {
            for declaration in spec.locks ?? []
            where declaration.name == resource && declaration.path != nil {
                guard let relative = declaration.path else { continue }
                let absolute = URL(fileURLWithPath: project).appending(path: relative)
                    .standardizedFileURL.path
                /** The path is documented as project-relative, so enforce it
                    rather than trusting it. A committed `{"path": "../.."}` would
                    otherwise aim the fingerprint at somewhere the project has no
                    business reading. */
                guard absolute == root || absolute.hasPrefix(prefix) else {
                    throw WireError(
                        code: .configInvalid,
                        hint: "run: devctl config check",
                        message:
                            "server '\(spec.name)': resource '\(resource)' declares state path '\(relative)', which resolves outside the project; a lock's state path must stay inside \(root)"
                    )
                }
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
