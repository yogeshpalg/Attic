import Foundation
import AppKit

/// An app that is installed right now.
struct InstalledApp: Sendable, Identifiable, Equatable, Hashable {

    let bundleURL: URL
    let identifier: String
    let name: String
    let version: String?

    var id: String { identifier }
}

/// Everything an app has put on this Mac: the bundle, and the files it wrote
/// elsewhere under its own identifier.
struct AppFootprint: Sendable, Equatable {

    let app: InstalledApp
    /// Size of the bundle in `/Applications` itself.
    let bundleBytes: Int64
    /// Support files, caches, preferences and containers, largest first.
    let supportPaths: [URL]
    let supportBytes: Int64
    /// True when the app is running. macOS will happily move a running app to
    /// the Trash and the result is a confused process with no files, so this is
    /// asked before anything is offered.
    let isRunning: Bool

    var totalBytes: Int64 { bundleBytes + supportBytes }
    var everything: [URL] { [app.bundleURL] + supportPaths }
}

/// Lists installed apps and works out what each one would leave behind.
///
/// macOS has no uninstall API — no registry, no receipts database that covers
/// anything but Apple's own installers. An app is a bundle, and uninstalling it
/// is deleting that bundle plus the files it wrote under its bundle identifier.
/// That is all any third-party uninstaller does, and all this does.
///
/// What is deliberately never offered:
///
/// - Anything under `/System`, which System Integrity Protection would refuse
///   anyway, so offering it would be a button that cannot work.
/// - Apple's own identifiers, for the same reason as in `OrphanStore`: a missing
///   app does not mean the data behind it is rubbish.
/// - Attic itself. An app that offers to delete itself mid-removal is a bug
///   waiting to be filed.
struct InstalledAppStore: Sendable {

    let folders: [URL]
    let supportLocations: [OrphanLocation]
    /// Injected so tests can decide what is running without launching anything.
    let runningIdentifiers: @Sendable () -> Set<String>

    init(
        folders: [URL],
        supportLocations: [OrphanLocation],
        runningIdentifiers: @Sendable @escaping () -> Set<String> = InstalledAppStore.running
    ) {
        self.folders = folders
        self.supportLocations = supportLocations
        self.runningIdentifiers = runningIdentifiers
    }

    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstalledAppStore {
        InstalledAppStore(
            folders: [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/Applications/Utilities"),
                home.appending(path: "Applications"),
            ],
            supportLocations: OrphanLocation.standard(home: home)
        )
    }

    @Sendable
    static func running() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// The identifier of the app doing the asking, so it never lists itself.
    static var ownIdentifier: String {
        Bundle.main.bundleIdentifier ?? "dev.yogesh.attic"
    }

    /// Installed apps, by name, with Apple's own and this app excluded.
    func apps() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]

        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: folder.path
            )) ?? []

            for name in names.sorted() where name.hasSuffix(".app") {
                let url = folder.appending(path: name)
                // A bundle under /System is protected by the system; a button
                // to remove it could only ever fail.
                guard PathContainment.contains(
                    root: URL(fileURLWithPath: "/System"), candidate: url
                ) == false else { continue }

                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier,
                      !BundleIdentifier.isApple(identifier),
                      identifier != Self.ownIdentifier
                else { continue }

                let info = bundle.infoDictionary
                found[identifier] = InstalledApp(
                    bundleURL: url,
                    identifier: identifier,
                    name: (info?["CFBundleName"] as? String)
                        ?? url.deletingPathExtension().lastPathComponent,
                    version: info?["CFBundleShortVersionString"] as? String
                )
            }
        }

        return found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// What removing this app would take with it.
    func footprint(for app: InstalledApp) -> AppFootprint {
        var paths: [URL] = []

        for location in supportLocations {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: location.directory.path
            )) ?? []

            for name in names.sorted() {
                // Matched whole, never by prefix: `com.example.bar` must not
                // drag `com.example.barista` out with it.
                guard location.identifier(forName: name) == app.identifier else { continue }
                paths.append(location.directory.appending(path: name))
            }
        }

        let measured = paths.map { (path: $0, bytes: DiskMeasure.measure($0).allocatedSize) }
        let ordered = measured.sorted { $0.bytes > $1.bytes }

        return AppFootprint(
            app: app,
            bundleBytes: DiskMeasure.measure(app.bundleURL).allocatedSize,
            supportPaths: ordered.map(\.path),
            supportBytes: ordered.reduce(0) { $0 + $1.bytes },
            isRunning: runningIdentifiers().contains(app.identifier)
        )
    }

    /// The findings and rules that carry an uninstall through the same planner
    /// and executor as everything else.
    ///
    /// Two rules rather than one, because the two halves live in different
    /// places and each has to be bounded by the folder it actually belongs to:
    /// the bundle by the folder it was installed into, the support files by
    /// `~/Library`. Nothing here gets a root that would let it reach further.
    static func removalPlanInputs(
        for footprint: AppFootprint,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (findings: [Finding], definitions: [RuleDefinition]) {
        let bundleRoot = footprint.app.bundleURL.deletingLastPathComponent()
        let library = home.appending(path: "Library")

        let bundleRule = RuleDefinition(
            id: "uninstall.bundle",
            minAppVersion: "1.0",
            category: .removedApps,
            displayName: footprint.app.name,
            root: .absolute(bundleRoot.path),
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .checkFirst,
            status: .active,
            explanation: Self.explanation(for: footprint)
        )

        let supportRule = RuleDefinition(
            id: "uninstall.support",
            minAppVersion: "1.0",
            category: .removedApps,
            displayName: "\(footprint.app.name) support files",
            root: .absolute(library.path),
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .checkFirst,
            status: .active,
            explanation: Self.explanation(for: footprint)
        )

        var findings: [Finding] = [
            Finding(
                id: "uninstall.bundle.\(footprint.app.identifier)",
                ruleID: bundleRule.id,
                category: .removedApps,
                displayName: footprint.app.name,
                subtitle: footprint.app.version.map { "version \($0)" } ?? "the app itself",
                paths: [footprint.app.bundleURL],
                fileCount: 1,
                allocatedSize: footprint.bundleBytes,
                lastUsed: nil,
                grade: .checkFirst,
                action: .trash,
                privilege: .user,
                explanation: Self.explanation(for: footprint),
                status: .active
            )
        ]

        if !footprint.supportPaths.isEmpty {
            findings.append(
                Finding(
                    id: "uninstall.support.\(footprint.app.identifier)",
                    ruleID: supportRule.id,
                    category: .removedApps,
                    displayName: "\(footprint.app.name) support files",
                    subtitle: "\(footprint.supportPaths.count) places",
                    paths: footprint.supportPaths,
                    fileCount: footprint.supportPaths.count,
                    allocatedSize: footprint.supportBytes,
                    lastUsed: nil,
                    grade: .checkFirst,
                    action: .trash,
                    privilege: .user,
                    explanation: Self.explanation(for: footprint),
                    status: .active
                )
            )
        }

        return (findings, [bundleRule, supportRule])
    }

    private static func explanation(for footprint: AppFootprint) -> Explanation {
        Explanation(
            whatThisIs: """
                \(footprint.app.name) and the settings, caches and saved data it \
                wrote under its own identifier. macOS has no uninstaller, so these \
                files stay behind when an app is dragged to the Trash.
                """,
            whatStopsWorking: """
                \(footprint.app.name) will not launch, and reinstalling it later \
                gives you a fresh copy with none of its old settings, accounts or \
                local data.
                """,
            doesItComeBack: """
                The app comes back if you install it again. Its settings and local \
                data do not, so take a copy of anything you still want first.
                """
        )
    }
}
