import Foundation

/// Paths no scanner and no definition may ever target, compiled into the binary.
/// A fetched definition cannot add to this list and cannot override it.
///
/// Note on `~/Library/Developer/Xcode/UserData`: the parent is deliberately *not*
/// listed. Previews, IB Support and the assistant's snapshot store all live inside
/// it and are legitimately reclaimable, so the protection is applied to the
/// specific unrecoverable leaves instead.
enum Denylist {

    private static func home(_ relative: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: relative)
    }

    static let paths: [URL] = [
        home("Documents"),
        home("Desktop"),
        URL(fileURLWithPath: "/System"),
        URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC"),
        home("Library/Application Support/MobileSync/Backup"),

        // dSYMs for shipped builds. Needed to symbolicate crash reports from
        // versions already in the App Store, and not recoverable once gone.
        home("Library/Developer/Xcode/Archives"),

        // Hand-made or signing-critical configuration inside UserData.
        home("Library/Developer/Xcode/UserData/Provisioning Profiles"),
        home("Library/Developer/Xcode/UserData/KeyBindings"),
        home("Library/Developer/Xcode/UserData/CodeSnippets"),
        home("Library/Developer/Xcode/UserData/FontAndColorThemes"),
        home("Library/Developer/Xcode/UserData/Debugger"),
        home("Library/MobileDevice/Provisioning Profiles"),
    ]

    /// Directory names that are never removable anywhere beneath a given root.
    /// The assistant's `memory` directories are authored state, not a transcript.
    static let protectedComponents: [(root: URL, name: String)] = [
        (home("Library/Developer/Xcode/CodingAssistant"), "memory")
    ]

    /// True when `url` is safe to emit. Containment is checked in **both**
    /// directions: a candidate inside a denied path is rejected, and so is a
    /// candidate that *contains* one, because selecting the parent would sweep it.
    static func permits(_ url: URL) -> Bool {
        let candidate = PathContainment.canonical(url)
        for denied in paths where PathContainment.overlaps(candidate, PathContainment.canonical(denied)) {
            return false
        }
        for rule in protectedComponents {
            let root = PathContainment.canonical(rule.root)
            guard PathContainment.contains(root: root, candidate: candidate) else { continue }
            if candidate.pathComponents.contains(rule.name) { return false }
        }
        return true
    }

    /// Distinguishes the two rejection kinds for reporting.
    static func rejection(for url: URL) -> RejectionReason? {
        let candidate = PathContainment.canonical(url)
        for denied in paths where PathContainment.overlaps(candidate, PathContainment.canonical(denied)) {
            return .denylisted
        }
        for rule in protectedComponents {
            let root = PathContainment.canonical(rule.root)
            guard PathContainment.contains(root: root, candidate: candidate) else { continue }
            if candidate.pathComponents.contains(rule.name) { return .protectedComponent }
        }
        return nil
    }
}
