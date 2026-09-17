import Foundation

/// Path containment, compared component-wise after symlink resolution.
///
/// String prefixes are not used anywhere: `/Users/me/Library/Dev` is a string
/// prefix of `/Users/me/Library/Developer` but is not a parent of it, and a rule
/// rooted at the former must never be allowed to claim paths in the latter.
enum PathContainment {

    /// Resolves symlinks and normalises `.` / `..`. This is what turns `/var/folders/…`
    /// into `/private/var/folders/…`, and it is why containment must be checked on
    /// canonical forms — a SwiftPM checkout symlinked out of a scanned tree would
    /// otherwise pass a naive check.
    ///
    /// `resolvingSymlinksInPath()` is deliberately not used: it strips a `/private`
    /// prefix instead of resolving to it, and it leaves paths that do not exist
    /// untouched, so `/var/folders` and `/private/var/folders/xx/yy` would never
    /// meet. `realpath(3)` resolves in the one direction the filesystem agrees on.
    static func canonical(_ url: URL) -> URL {
        var existing = URL(fileURLWithPath: url.path).standardizedFileURL
        var trailing: [String] = []

        // realpath only answers for paths that exist. Peel components off the end
        // until an ancestor resolves, then re-apply them, so a path that has not
        // been created yet still canonicalises against its real parent.
        while true {
            if let real = resolveExisting(existing.path) {
                // Not standardised again on the way out: standardisation strips a
                // leading `/private`, which would undo the resolution.
                var result = URL(fileURLWithPath: real)
                for component in trailing.reversed() {
                    result.append(path: component)
                }
                return result
            }

            let parent = existing.deletingLastPathComponent().standardizedFileURL
            // Nothing along the path exists — keep the lexically normalised form.
            guard parent.path != existing.path else { return existing }

            trailing.append(existing.lastPathComponent)
            existing = parent
        }
    }

    private static func resolveExisting(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    /// True when `candidate` is the root itself or sits beneath it.
    static func contains(root: URL, candidate: URL) -> Bool {
        let rootParts = canonical(root).pathComponents
        let candidateParts = canonical(candidate).pathComponents
        guard candidateParts.count >= rootParts.count else { return false }
        return Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    /// True when either path contains the other. Used against the denylist, where
    /// a candidate that *contains* a protected path is just as dangerous as one
    /// inside it, because selecting it would sweep the protected path away.
    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        contains(root: a, candidate: b) || contains(root: b, candidate: a)
    }
}
