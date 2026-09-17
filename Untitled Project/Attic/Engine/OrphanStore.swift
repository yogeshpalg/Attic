import Foundation
import AppKit

/// Where an uninstalled app leaves things behind, and how the leftover is named.
///
/// Every location names its contents after the app's bundle identifier, which is
/// what makes them safe to match: an identifier is exact and owned, unlike a
/// folder called "Google" that three different things might have written.
struct OrphanLocation: Sendable, Equatable {

    /// What finding something here says about its owner. Only an app gets a
    /// container or a saved window position; a command-line tool writes a cache
    /// and nothing else. The distinction decides which of the two rules claims
    /// the leftovers, and so which sentence the user reads about them.
    enum Evidence: Sendable, Equatable {
        /// Only an app writes here.
        case application
        /// Anything at all writes here.
        case any
    }

    let directory: URL
    /// Appended to the identifier to form the name on disk, e.g. `.plist`.
    let suffix: String
    /// Stripped from the front before the identifier is read, for the folders
    /// whose names carry a prefix — Group Containers are `group.com.example`.
    let prefixes: [String]
    let evidence: Evidence

    init(
        _ directory: URL,
        suffix: String = "",
        prefixes: [String] = [],
        evidence: Evidence = .any
    ) {
        self.directory = directory
        self.suffix = suffix
        self.prefixes = prefixes
        self.evidence = evidence
    }

    /// The identifier a name in this location belongs to, or `nil` if the name is
    /// not shaped like one.
    func identifier(forName name: String) -> String? {
        guard suffix.isEmpty || name.hasSuffix(suffix) else { return nil }
        var candidate = suffix.isEmpty ? name : String(name.dropLast(suffix.count))

        if !prefixes.isEmpty {
            guard let prefix = prefixes.first(where: { candidate.hasPrefix($0) }) else {
                // A team identifier rather than a literal prefix: `A1B2C3D4E5.com.example`.
                guard let separator = candidate.firstIndex(of: "."),
                      BundleIdentifier.isTeamIdentifier(String(candidate[..<separator]))
                else { return nil }
                candidate = String(candidate[candidate.index(after: separator)...])
                return BundleIdentifier.isWellFormed(candidate) ? candidate : nil
            }
            candidate = String(candidate.dropFirst(prefix.count))
        }

        return BundleIdentifier.isWellFormed(candidate) ? candidate : nil
    }

    static func standard(home: URL) -> [OrphanLocation] {
        let library = home.appending(path: "Library")
        return [
            OrphanLocation(library.appending(path: "Application Support"), evidence: .application),
            OrphanLocation(library.appending(path: "Containers"), evidence: .application),
            OrphanLocation(library.appending(path: "Group Containers"), prefixes: ["group."], evidence: .application),
            OrphanLocation(library.appending(path: "HTTPStorages"), evidence: .application),
            OrphanLocation(library.appending(path: "WebKit"), evidence: .application),
            OrphanLocation(
                library.appending(path: "Saved Application State"),
                suffix: ".savedState",
                evidence: .application
            ),
            OrphanLocation(library.appending(path: "Preferences"), suffix: ".plist", evidence: .application),
            OrphanLocation(library.appending(path: "LaunchAgents"), suffix: ".plist"),
            OrphanLocation(library.appending(path: "Caches")),
            OrphanLocation(library.appending(path: "Logs")),
        ]
    }
}

enum BundleIdentifier {

    /// The first component of a real identifier is a domain suffix, because the
    /// convention is a domain written backwards. Checking for one is what keeps
    /// system data out of the list: `PFSceneTaxonomyData.index` and
    /// `DiscRecording.log` are dotted names sitting in the same folders, and
    /// offering someone's Photos index as "leftovers from an app you removed"
    /// would be exactly the wrong kind of guess.
    private static let domainSuffixes: Set<String> = [
        "com", "org", "net", "io", "co", "dev", "app", "me", "ai", "cloud", "gg", "tv", "xyz",
        "info", "biz", "edu", "gov", "mil", "int", "eu", "us", "uk", "ca", "au", "nz", "de",
        "fr", "es", "it", "nl", "se", "no", "dk", "fi", "pl", "pt", "ch", "at", "be", "ie",
        "cz", "gr", "hu", "ro", "ru", "ua", "tr", "il", "in", "jp", "kr", "cn", "tw", "hk",
        "sg", "my", "id", "th", "vn", "ph", "br", "mx", "ar", "cl", "za", "ng", "ke",
    ]

    /// Reverse-DNS shaped: a domain suffix, then at least one more plain
    /// component. "Google", "Sublime Text" and "minecraft" are things an app
    /// wrote under its own name, and no identifier can be matched to them
    /// exactly, so they are never offered.
    static func isWellFormed(_ candidate: String) -> Bool {
        let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        guard domainSuffixes.contains(components[0].lowercased()) else { return false }

        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        var sawLetter = false

        for component in components {
            guard !component.isEmpty else { return false }
            let lowered = component.lowercased()
            guard lowered.unicodeScalars.allSatisfy(permitted.contains) else { return false }
            if component.contains(where: \.isLetter) { sawLetter = true }
        }
        return sawLetter
    }

    /// A ten-character developer team identifier, which prefixes the name of a
    /// group container: `A1B2C3D4E5.com.example.shared`.
    static func isTeamIdentifier(_ candidate: String) -> Bool {
        candidate.count == 10 && candidate.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// Every identifier this one could belong to, longest first:
    /// `com.example.app.Helper` also answers to `com.example.app`.
    ///
    /// An app extension or updater has its own identifier and its own container,
    /// but it is not its own app — if the parent is installed, the child is not
    /// a leftover.
    static func ancestors(of identifier: String) -> [String] {
        let components = identifier.split(separator: ".").map(String.init)
        guard components.count > 2 else { return [] }

        return (2..<components.count).reversed().map { count in
            components.prefix(count).joined(separator: ".")
        }
    }

    /// Apple's own identifiers are never offered. A missing `.app` for one of
    /// these does not mean the data behind it is rubbish — plenty of system
    /// components keep state without shipping an app at all.
    static func isApple(_ identifier: String) -> Bool {
        identifier == "com.apple" || identifier.hasPrefix("com.apple.")
    }
}

/// Something left behind by software that is no longer installed.
struct Orphan: Sendable, Equatable {

    /// Whether the owner was an app or a command-line tool, decided by where the
    /// leftovers were found rather than guessed from the name.
    ///
    /// This matters for the sentence the user reads. `org.swift.swiftpm` is half
    /// a gigabyte of package cache with no app attached; calling it "left behind
    /// by an app you removed" would be false, and the cost of removing it — every
    /// dependency downloaded again — is nothing like losing an app's settings.
    enum Kind: Sendable, Equatable {
        case application
        case tool
    }

    let identifier: String
    let paths: [URL]
    let kind: Kind
}

/// Finds support files belonging to apps that are no longer installed.
///
/// The risk here is not deleting too little, it is deciding an app is gone when
/// it is not. Two things guard against that: identifiers are compared whole,
/// never by prefix — `com.example.bar` must never match `com.example.barista`,
/// the same trap `PathContainment` exists to avoid — and liveness is answered by
/// LaunchServices rather than by looking in `/Applications`, so an app built into
/// DerivedData or living in a folder nobody thought to scan still counts as here.
struct OrphanStore: Sendable {

    let locations: [OrphanLocation]
    /// Answers "is this app still on the Mac?". Injected so the decision can be
    /// tested without installing anything.
    let isInstalled: @Sendable (String) -> Bool

    init(
        locations: [OrphanLocation],
        isInstalled: @Sendable @escaping (String) -> Bool = OrphanStore.isKnownToLaunchServices
    ) {
        self.locations = locations
        self.isInstalled = isInstalled
    }

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> OrphanStore {
        OrphanStore(locations: OrphanLocation.standard(home: home))
    }

    /// LaunchServices knows about every app it has seen, wherever it lives, which
    /// is a far better question than "is there a bundle in /Applications".
    @Sendable
    static func isKnownToLaunchServices(_ identifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
    }

    /// Leftovers grouped by the identifier that owns them. Deterministic order,
    /// so the same Mac produces the same list twice.
    func orphans(kind: Orphan.Kind? = nil) -> [Orphan] {
        var paths: [String: [URL]] = [:]
        var isApp: Set<String> = []

        for location in locations {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: location.directory.path
            )) ?? []

            for name in names.sorted() {
                guard let identifier = location.identifier(forName: name) else { continue }
                guard !BundleIdentifier.isApple(identifier) else { continue }
                guard !isStillOwned(identifier) else { continue }

                paths[identifier, default: []].append(location.directory.appending(path: name))
                if location.evidence == .application { isApp.insert(identifier) }
            }
        }

        let all = paths
            .sorted { $0.key < $1.key }
            .map { entry in
                Orphan(
                    identifier: entry.key,
                    paths: entry.value,
                    kind: isApp.contains(entry.key) ? .application : .tool
                )
            }

        guard let kind else { return all }
        return all.filter { $0.kind == kind }
    }

    /// True when the app itself, or the app an extension belongs to, is still
    /// here. `com.example.app.Helper` is spared while `com.example.app` remains
    /// installed, because a helper is not its own app.
    private func isStillOwned(_ identifier: String) -> Bool {
        if isInstalled(identifier) { return true }
        return BundleIdentifier.ancestors(of: identifier).contains(where: isInstalled)
    }

    /// Components that name a platform or a build rather than an app.
    /// `com.kingsoft.wpsoffice.mac.global` ends in two of them, and "Global" is
    /// not the name of anything a person installed.
    private static let uninformative: Set<String> = [
        "app", "mac", "macos", "osx", "desktop", "client", "global", "x",
        "ios", "universal", "free", "pro", "lite", "beta", "release", "prod",
    ]

    /// The best name available for an app that is not here to ask. The identifier
    /// is shown alongside it, because a guessed name should never be the only
    /// thing a person has to go on.
    static func readableName(for identifier: String) -> String {
        let components = identifier.split(separator: ".")
        // Walk back past the components that describe a platform rather than a
        // product, but never past the domain itself — `com` names nothing.
        let meaningful = components
            .dropFirst()
            .last { !uninformative.contains($0.lowercased()) }

        guard let last = meaningful ?? components.last, !last.isEmpty else {
            return identifier
        }

        // Identifiers are written in camel case as often as not, so
        // `slackmacgap` stays as it is while `VisualStudioCode` is split up.
        var words: [String] = []
        var current = ""
        for character in last {
            if character.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }

        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
