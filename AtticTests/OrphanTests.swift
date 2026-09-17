import Testing
import Foundation
@testable import Attic

/// Invariant 17. Finding leftovers from an app that is gone means deciding an app
/// is gone, and that is the whole risk of the feature. Two guards carry it:
/// identifiers are matched whole, never by prefix, and liveness is answered by
/// LaunchServices rather than by looking in `/Applications` — so an app built
/// into DerivedData or living somewhere nobody thought to scan still counts.
@Suite("Bundle identifiers")
struct BundleIdentifierTests {

    @Test("A reverse-DNS identifier is recognised")
    func wellFormedIdentifiersAreRecognised() {
        #expect(BundleIdentifier.isWellFormed("com.tinyspeck.slackmacgap"))
        #expect(BundleIdentifier.isWellFormed("org.mozilla.firefox"))
        #expect(BundleIdentifier.isWellFormed("dev.yogesh.Attic"))
        #expect(BundleIdentifier.isWellFormed("com.microsoft.VSCode"))
        #expect(BundleIdentifier.isWellFormed("io.crate-db.client_1"))
    }

    @Test("An ordinary folder name is not treated as an identifier")
    func plainNamesAreNotIdentifiers() {
        // These are folders an app wrote under its own name. There is no
        // identifier to compare them against, so they are never offered.
        #expect(BundleIdentifier.isWellFormed("Google") == false)
        #expect(BundleIdentifier.isWellFormed("Sublime Text") == false)
        #expect(BundleIdentifier.isWellFormed("minecraft") == false)
        #expect(BundleIdentifier.isWellFormed("") == false)
        #expect(BundleIdentifier.isWellFormed(".") == false)
        #expect(BundleIdentifier.isWellFormed("com.") == false)
        #expect(BundleIdentifier.isWellFormed(".com") == false)
        #expect(BundleIdentifier.isWellFormed("1.2") == false)
        #expect(BundleIdentifier.isWellFormed("My App.app") == false)
    }

    @Test("A dotted system file name is not an identifier")
    func dottedSystemFilesAreNotIdentifiers() {
        // All four of these sit in ~/Library/Logs or ~/Library/Caches on a real
        // Mac, none of them is `com.apple.*`, and one is 2 MB of Photos index
        // data. Offering them as an uninstalled app's leftovers is the exact
        // wrong guess, and a dotted name alone was enough to make it.
        #expect(BundleIdentifier.isWellFormed("PFSceneTaxonomyData.index") == false)
        #expect(BundleIdentifier.isWellFormed("PhotosSearch.aapbz") == false)
        #expect(BundleIdentifier.isWellFormed("PhotosUpgrade.aapbz") == false)
        #expect(BundleIdentifier.isWellFormed("DiscRecording.log") == false)

        // A real identifier starts with a domain suffix, written backwards.
        #expect(BundleIdentifier.isWellFormed("com.amazon.Kindle"))
        #expect(BundleIdentifier.isWellFormed("io.tailscale.ipn.macos"))
    }

    @Test("An extension belongs to the app above it")
    func ancestorsAreListedLongestFirst() {
        #expect(
            BundleIdentifier.ancestors(of: "com.example.app.Helper.Updater")
                == ["com.example.app.Helper", "com.example.app", "com.example"]
        )
        #expect(BundleIdentifier.ancestors(of: "com.example.app") == ["com.example"])
        // Nothing above a two-component identifier is worth asking about.
        #expect(BundleIdentifier.ancestors(of: "com.example").isEmpty)
    }

    @Test("Apple's own identifiers are never offered")
    func appleIdentifiersAreExcluded() {
        // A missing `.app` for one of these does not mean the data is rubbish:
        // plenty of system components keep state without shipping an app.
        #expect(BundleIdentifier.isApple("com.apple.dt.Xcode"))
        #expect(BundleIdentifier.isApple("com.apple"))
        #expect(BundleIdentifier.isApple("com.apple.Safari"))

        // Not Apple, despite the prefix looking close.
        #expect(BundleIdentifier.isApple("com.applesauce.jam") == false)
        #expect(BundleIdentifier.isApple("com.tinyspeck.slackmacgap") == false)
    }
}

@Suite("Orphan detection")
struct OrphanStoreTests {

    /// Builds the nine leftover folders inside a throwaway tree.
    private func library(_ tree: FixtureTree) throws -> [OrphanLocation] {
        for folder in [
            "Application Support", "Caches", "Containers", "Group Containers", "HTTPStorages",
            "WebKit", "Logs", "Preferences", "LaunchAgents", "Saved Application State",
        ] {
            try tree.directory("Library/\(folder)")
        }
        return OrphanLocation.standard(home: tree.root)
    }

    @Test("Leftovers from an app that is gone are found across every folder")
    func orphansAreGroupedByOwner() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)

        try tree.file("Library/Application Support/com.gone.app/data.db")
        try tree.file("Library/Caches/com.gone.app/cache.bin")
        try tree.file("Library/Preferences/com.gone.app.plist")
        try tree.file("Library/Saved Application State/com.gone.app.savedState/window.data")

        let orphans = OrphanStore(locations: locations, isInstalled: { _ in false })
            .orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.count == 1)
        #expect(orphans.first?.identifier == "com.gone.app")
        // One decision, not four.
        #expect(orphans.first?.paths.count == 4)
    }

    @Test("An installed app's files are left alone")
    func installedAppsAreNotOrphans() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Caches/com.here.app/cache.bin")
        try tree.file("Library/Caches/com.gone.app/cache.bin")

        let orphans = OrphanStore(
            locations: locations,
            isInstalled: { $0 == "com.here.app" }
        ).orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.map(\.identifier) == ["com.gone.app"])
    }

    @Test("An identifier that merely shares a prefix is a different app")
    func prefixesDoNotCount() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Caches/com.example.bar/cache.bin")
        try tree.file("Library/Caches/com.example.barista/cache.bin")

        // `com.example.bar` is installed; `com.example.barista` is not. Matching
        // by prefix would call the installed one's leftovers orphaned, or spare
        // the uninstalled one — the same trap `PathContainment` exists to avoid.
        let orphans = OrphanStore(
            locations: locations,
            isInstalled: { $0 == "com.example.bar" }
        ).orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.map(\.identifier) == ["com.example.barista"])
    }

    @Test("An extension is spared while the app it belongs to is installed")
    func extensionsOfInstalledAppsAreSpared() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Containers/com.here.app.WidgetExtension/data.bin")
        try tree.file("Library/Containers/com.here.app.ShipIt/updater.bin")
        try tree.file("Library/Containers/com.gone.app.WidgetExtension/data.bin")

        // Only the parent app is registered. Its extensions have their own
        // identifiers and their own containers, but they are not their own apps.
        let orphans = OrphanStore(
            locations: locations,
            isInstalled: { $0 == "com.here.app" }
        ).orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.map(\.identifier) == ["com.gone.app.WidgetExtension"])
    }

    @Test("Folders named after an app rather than its identifier are never offered")
    func plainlyNamedFoldersAreIgnored() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Application Support/Google/chrome.db")
        try tree.file("Library/Application Support/Sublime Text/session.json")
        try tree.file("Library/Caches/com.gone.app/cache.bin")

        let orphans = OrphanStore(locations: locations, isInstalled: { _ in false })
            .orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        // "Google" cannot be checked against anything, so it is not guessed at.
        #expect(orphans.map(\.identifier) == ["com.gone.app"])
    }

    @Test("Apple's files are never offered, installed or not")
    func appleFilesAreNeverOffered() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Caches/com.apple.Safari/cache.bin")
        try tree.file("Library/Preferences/com.apple.finder.plist")

        let orphans = OrphanStore(locations: locations, isInstalled: { _ in false })
            .orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.isEmpty)
    }

    @Test("A suffix has to match before a name counts")
    func suffixesAreRequired() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        // Preferences holds `<id>.plist`; a bare directory there is not a
        // preference file for `com.gone.app`.
        try tree.file("Library/Preferences/com.gone.app.plist")
        try tree.directory("Library/Preferences/com.other.app")

        let orphans = OrphanStore(locations: locations, isInstalled: { _ in false })
            .orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.map(\.identifier) == ["com.gone.app"])
    }

    @Test("A location that does not exist yields nothing rather than failing")
    func missingLocationsAreSkipped() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let store = OrphanStore(
            locations: OrphanLocation.standard(home: tree.root),
            isInstalled: { _ in false }
        )

        #expect(store.orphans().isEmpty)
    }

    @Test("The listing is in a stable order")
    func orderIsDeterministic() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        for identifier in ["com.c.app", "com.a.app", "com.b.app"] {
            try tree.file("Library/Caches/\(identifier)/cache.bin")
        }

        let store = OrphanStore(locations: locations, isInstalled: { _ in false })

        #expect(store.orphans().map(\.identifier) == ["com.a.app", "com.b.app", "com.c.app"])
        #expect(store.orphans().map(\.identifier) == store.orphans().map(\.identifier))
    }

    @Test("Group containers are matched through their prefix")
    func groupContainersAreMatched() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Group Containers/group.com.gone.app/shared.db")
        try tree.file("Library/Group Containers/A1B2C3D4E5.com.gone.suite/shared.db")
        // Neither a group prefix nor a team identifier, so not an identifier.
        try tree.file("Library/Group Containers/notateam.com.gone.other/shared.db")

        let orphans = OrphanStore(locations: locations, isInstalled: { _ in false })
            .orphans().map { (identifier: $0.identifier, paths: $0.paths) }

        #expect(orphans.map(\.identifier) == ["com.gone.app", "com.gone.suite"])
    }

    @Test("A team identifier is ten characters of upper case and digits")
    func teamIdentifiersAreRecognised() {
        #expect(BundleIdentifier.isTeamIdentifier("A1B2C3D4E5"))
        #expect(BundleIdentifier.isTeamIdentifier("ABCDE12345"))
        #expect(BundleIdentifier.isTeamIdentifier("abcde12345") == false)
        #expect(BundleIdentifier.isTeamIdentifier("TOOSHORT") == false)
        #expect(BundleIdentifier.isTeamIdentifier("WAYTOOLONGFORATEAM") == false)
    }

    @Test("A container marks its owner as an app; a cache alone does not")
    func evidenceDecidesTheKind() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        // An app: it had a container.
        try tree.file("Library/Containers/com.gone.app/data.bin")
        try tree.file("Library/Caches/com.gone.app/cache.bin")
        // A tool: a cache and nothing else. `org.swift.swiftpm` is the real one,
        // at half a gigabyte, and calling it an app would be a lie.
        try tree.file("Library/Caches/org.swift.swiftpm/repos.bin")
        try tree.file("Library/Logs/org.swift.swiftpm/build.log")

        let store = OrphanStore(locations: locations, isInstalled: { _ in false })

        #expect(store.orphans(kind: .application).map(\.identifier) == ["com.gone.app"])
        #expect(store.orphans(kind: .tool).map(\.identifier) == ["org.swift.swiftpm"])
        // Asking for neither kind returns both, each labelled.
        #expect(store.orphans().count == 2)
    }

    @Test("A preference file is enough to call something an app")
    func preferencesCountAsApplicationEvidence() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locations = try library(tree)
        try tree.file("Library/Preferences/com.gone.app.plist")

        let store = OrphanStore(locations: locations, isInstalled: { _ in false })

        #expect(store.orphans(kind: .application).map(\.identifier) == ["com.gone.app"])
        #expect(store.orphans(kind: .tool).isEmpty)
    }

    @Test("LaunchServices is what answers whether an app is still here")
    func livenessComesFromLaunchServices() {
        // Finder is always installed; this identifier never is.
        #expect(OrphanStore.isKnownToLaunchServices("com.apple.finder"))
        #expect(OrphanStore.isKnownToLaunchServices("com.attic.definitely-not-installed") == false)
    }
}

@Suite("Naming an app that is gone")
struct OrphanNameTests {

    @Test("The last component becomes the name shown")
    func lastComponentIsUsed() {
        #expect(OrphanStore.readableName(for: "com.tinyspeck.slackmacgap") == "Slackmacgap")
        #expect(OrphanStore.readableName(for: "org.mozilla.firefox") == "Firefox")
    }

    @Test("Camel case is split into words")
    func camelCaseIsSplit() {
        #expect(OrphanStore.readableName(for: "com.microsoft.VisualStudioCode") == "Visual Studio Code")
        #expect(OrphanStore.readableName(for: "com.example.myGreatApp") == "My Great App")
    }

    @Test("A name that cannot be improved is left as it is")
    func unhelpfulIdentifiersAreLeftAlone() {
        #expect(OrphanStore.readableName(for: "com.example") == "Example")
        #expect(OrphanStore.readableName(for: "single") == "Single")
    }

    @Test("Platform and build components are not mistaken for the app's name")
    func platformComponentsAreSkipped() {
        // Seen on a real Mac: the last component is "global", which is the name
        // of nothing anybody installed.
        #expect(OrphanStore.readableName(for: "com.kingsoft.wpsoffice.mac.global") == "Wpsoffice")
        #expect(OrphanStore.readableName(for: "com.goodnotesapp.x") == "Goodnotesapp")
        #expect(OrphanStore.readableName(for: "com.example.editor.desktop") == "Editor")
        #expect(OrphanStore.readableName(for: "com.microsoft.edgemac") == "Edgemac")
    }

    @Test("The domain is never used as the name")
    func domainIsNeverTheName() {
        // Every component after the domain is uninformative, so the closest
        // thing to a name is the vendor — never "com".
        #expect(OrphanStore.readableName(for: "com.vendor.mac") == "Vendor")
        #expect(OrphanStore.readableName(for: "io.tool.app.desktop") == "Tool")
    }
}
