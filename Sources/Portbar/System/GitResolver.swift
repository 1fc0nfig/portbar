import Foundation

/// Where a directory sits in git: which repository, which worktree, which branch.
struct GitLocation: Hashable {
    /// Root of the main checkout. All worktrees of one repository share it.
    let repoRoot: String
    /// Root of this checkout (equal to `repoRoot` for the main worktree).
    let worktreeRoot: String
    let branch: String
    var isLinkedWorktree: Bool { repoRoot != worktreeRoot }
    var repoName: String { (repoRoot as NSString).lastPathComponent }
}

/// Resolves directories to git locations by reading `.git` files directly. No `git` subprocess.
final class GitResolver {
    private struct Checkout { let repoRoot: String; let worktreeRoot: String; let gitDir: String }
    private var checkoutCache: [String: Checkout?] = [:]
    private let fm = FileManager.default

    func locate(_ directory: String) -> GitLocation? {
        guard let checkout = checkout(for: directory) else { return nil }
        return GitLocation(repoRoot: checkout.repoRoot,
                           worktreeRoot: checkout.worktreeRoot,
                           branch: branch(gitDir: checkout.gitDir))
    }

    /// Drops cached lookups so new or deleted worktrees show up.
    func invalidate() { checkoutCache.removeAll() }

    private func checkout(for directory: String) -> Checkout? {
        if let cached = checkoutCache[directory] { return cached }
        var found: Checkout?
        var dir = directory
        while !dir.isEmpty, dir != "/" {
            if let parentCached = checkoutCache[dir] { found = parentCached; break }
            if let c = checkoutAt(dir) { found = c; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        // Home directory dotfile repos would swallow everything. Ignore them.
        if let f = found, f.worktreeRoot == NSHomeDirectory() { found = nil }
        checkoutCache[directory] = found
        return found
    }

    private func checkoutAt(_ dir: String) -> Checkout? {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            return Checkout(repoRoot: dir, worktreeRoot: dir, gitDir: dotGit)
        }

        // Linked worktree or submodule: `.git` is a file with "gitdir: <path>".
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") { gitDir = (dir as NSString).appendingPathComponent(gitDir) }
        gitDir = (gitDir as NSString).standardizingPath

        let commondirFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let common = try? String(contentsOfFile: commondirFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            // Submodule: treat as its own repository.
            return Checkout(repoRoot: dir, worktreeRoot: dir, gitDir: gitDir)
        }
        var commonDir = common.hasPrefix("/") ? common : (gitDir as NSString).appendingPathComponent(common)
        commonDir = (commonDir as NSString).standardizingPath
        let repoRoot = (commonDir as NSString).lastPathComponent == ".git"
            ? (commonDir as NSString).deletingLastPathComponent
            : commonDir   // bare repository
        return Checkout(repoRoot: repoRoot, worktreeRoot: dir, gitDir: gitDir)
    }

    private func branch(gitDir: String) -> String {
        let head = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let text = try? String(contentsOfFile: head, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "?" }
        if text.hasPrefix("ref: refs/heads/") { return String(text.dropFirst("ref: refs/heads/".count)) }
        return String(text.prefix(7))   // detached HEAD
    }
}
