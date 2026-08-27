import Foundation

/** Git checkout identity helpers for sibling port rebind and the worktree
    display label. Shells out to `git`; failures return nil so non-git
    projects keep the pre-coexistence path. */
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

    /** Display label for a linked worktree: the sanitized checkout directory
        name, shown in status and session context so a reader can tell which
        checkout a server belongs to. The label never touches the host: every
        `*.localhost` name resolves to loopback, so the host disambiguated
        nothing, and a third-level subdomain breaks apps whose auth config
        (callback allow lists, cookie domains, trusted origins) pins one
        origin. Sibling checkouts are told apart by the rebound port instead.
        Main checkouts and non-git trees return nil. */
    public static func worktreeLabel(project: String) -> String? {
        guard isLinkedWorktree(project: project) else { return nil }
        return sanitizeLabel((project as NSString).lastPathComponent)
    }

    /** Stable free-port candidate near the declared port for sibling rebind. */
    public static func siblingPortCandidate(declared: Int, project: String) -> Int {
        let offset = (Int(DevCtlPaths.hash8(project).prefix(4), radix: 16) ?? 1) % 1000
        let base = declared + offset + 1
        return min(max(base, 1024), 65_000)
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
