import Foundation

/** One home for resolving a server's `watch` entries, so `config check` warns
    about exactly the entries the daemon will ignore. */
public enum WatchPaths {
    /** Resolves project-relative watch entries to absolute paths, dropping the
        ones directa will not follow and saying why. Warnings rather than errors:
        a stray watch entry must not block a whole project's config. */
    public static func resolve(entries: [String], project: String)
        -> (paths: [String], warnings: [String])
    {
        var paths: [String] = []
        var warnings: [String] = []
        let root = URL(fileURLWithPath: project).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for entry in entries {
            guard !entry.isEmpty else {
                warnings.append("watch entry is empty")
                continue
            }
            /** No globs: matching would turn a handful of stats into a tree walk
                on every sweep, and it makes "what bounces my server" unpredictable
                in a file an agent may write unattended. */
            if entry.contains(where: { "*?[{".contains($0) }) {
                warnings.append(
                    "watch entry '\(entry)' looks like a glob; list the files literally")
                continue
            }
            if entry.hasPrefix("/") {
                warnings.append(
                    "watch entry '\(entry)' is absolute; watch paths are relative to the project root")
                continue
            }
            let absolute = URL(fileURLWithPath: project).appending(path: entry)
                .standardizedFileURL.path
            /** `absolute == root` is admitted so this answers the same question
                as `LockResource.statePath`, which already allows a declaration
                resolving to the project root itself. A root entry is then
                rejected below as a directory, with the message a reader can act
                on, instead of being called an escape it is not. */
            guard absolute == root || absolute.hasPrefix(prefix) else {
                warnings.append("watch entry '\(entry)' points outside the project")
                continue
            }
            var info = stat()
            if stat(absolute, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                warnings.append("watch entry '\(entry)' is a directory; list the files inside it")
                continue
            }
            paths.append(absolute)
        }
        return (paths: Array(Set(paths)).sorted(), warnings: warnings)
    }
}
