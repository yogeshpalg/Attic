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
    static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).resolvingSymlinksInPath().standardizedFileURL
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
