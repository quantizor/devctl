import Foundation

/** Git checkout identity helpers for sibling port rebind and ephemeral worktree
    hosts. Shells out to `git`; failures return nil so non-git projects keep the
    pre-coexistence path. */
public enum CheckoutIdentity {
    /** Absolute path to the shared git directory, or nil if not a git checkout. */
    public static func gitCommonDir(project: String) -> String? {
        git(project: project, args: ["rev-parse", "--git-common-dir"]).map {
            canonicalProjectPath(absoluteGitPath($0, project: project))
        }
    }

    /** True when this path is a linked worktree (git-dir differs from common-dir,
        or `.git` is a file). Main checkouts and non-git trees return false. */
    public static func isLinkedWorktree(project: String) -> Bool {
        let gitFile = URL(fileURLWithPath: project).appending(path: ".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDir), !isDir.boolValue {
            return true
        }
        guard let common = gitCommonDir(project: project),
            let gitDir = git(project: project, args: ["rev-parse", "--git-dir"]).map({
                canonicalProjectPath(absoluteGitPath($0, project: project))
            })
        else { return false }
        return common != gitDir
    }

    /** Preferred subdomain for the project family: committed host without
        `.localhost`, else the main worktree path's slug, else this path's slug. */
    public static func preferredSubdomain(project: String, committedHost: String?) -> String {
        if let committedHost {
            let trimmed = committedHost.hasSuffix(".localhost")
                ? String(committedHost.dropLast(".localhost".count))
                : committedHost
            let leaf = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
            if !leaf.isEmpty { return sanitizeLabel(leaf) }
        }
        if let main = mainWorktreePath(project: project) {
            return ProjectConfigLoader.defaultSlug(project: main)
        }
        return ProjectConfigLoader.defaultSlug(project: project)
    }

    /** Ephemeral host for a linked worktree: `worktree-<label>.<preferred>.localhost`.
        Main checkouts return nil so the caller keeps the stable preferred host. */
    public static func worktreeHost(
        project: String, preferred: String, takenHosts: Set<String> = []
    ) -> String? {
        guard isLinkedWorktree(project: project) else { return nil }
        let label = sanitizeLabel((project as NSString).lastPathComponent)
        var host = "worktree-\(label).\(preferred).localhost"
        if takenHosts.contains(host) {
            let hash = DevCtlPaths.hash8(project).prefix(4)
            host = "worktree-\(label)-\(hash).\(preferred).localhost"
        }
        return host
    }

    /** Stable free-port candidate near the declared port for sibling rebind. */
    public static func siblingPortCandidate(declared: Int, project: String) -> Int {
        let offset = (Int(DevCtlPaths.hash8(project).prefix(4), radix: 16) ?? 1) % 1000
        let base = declared + offset + 1
        return min(max(base, 1024), 65_000)
    }

    /** Absolute path of the primary worktree, when discoverable. */
    public static func mainWorktreePath(project: String) -> String? {
        guard let listing = git(project: project, args: ["worktree", "list", "--porcelain"])
        else { return nil }
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                let path = String(line.dropFirst("worktree ".count))
                return canonicalProjectPath(path)
            }
        }
        return nil
    }

    public static func sanitizeLabel(_ raw: String) -> String {
        raw.lowercased()
            .replacing(/[^a-z0-9-]+/) { _ in "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func shareCommonDir(_ a: String, _ b: String) -> Bool {
        guard let left = gitCommonDir(project: a), let right = gitCommonDir(project: b) else {
            return false
        }
        return left == right
    }

    private static func absoluteGitPath(_ path: String, project: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: project).appending(path: path).path
    }

    private static func git(project: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}
