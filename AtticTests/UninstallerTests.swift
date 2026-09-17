import Testing
import Foundation
@testable import Attic

/// Invariant 22. macOS has no uninstaller and no API for one: an app is a bundle,
/// and removing it means moving that bundle and the files it wrote under its own
/// identifier to the Trash. That is all any uninstaller on this platform does,
/// and it puts three things at risk — taking the wrong app's files, touching
/// something the system protects, and pulling the disk out from under a running
/// process. Each one has a guard here.
@Suite("Installed apps")
struct InstalledAppStoreTests {

    /// A throwaway `/Applications` with real bundles in it. Most tests only care
    /// that the bundle exists, so the URL it returns is optional to use.
    @discardableResult
    private func makeApp(
        _ tree: FixtureTree,
        folder: String,
        name: String,
        identifier: String,
        version: String = "1.0"
    ) throws -> URL {
        let bundle = try tree.directory("\(folder)/\(name).app/Contents")
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key><string>\(identifier)</string>
                <key>CFBundleName</key><string>\(name)</string>
                <key>CFBundleShortVersionString</key><string>\(version)</string>
                <key>CFBundleExecutable</key><string>\(name)</string>
            </dict>
            </plist>
            """
        try plist.data(using: .utf8)!.write(to: bundle.appending(path: "Info.plist"))
        try tree.file("\(folder)/\(name).app/Contents/MacOS/\(name)", bytes: 16_384)
        return tree.root.appending(path: "\(folder)/\(name).app")
    }

    private func store(_ tree: FixtureTree, running: Set<String> = []) -> InstalledAppStore {
        InstalledAppStore(
            folders: [tree.root.appending(path: "Applications")],
            supportLocations: OrphanLocation.standard(home: tree.root),
            runningIdentifiers: { running }
        )
    }

    @Test("Installed apps are listed with their name, identifier and version")
    func appsAreListed() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try makeApp(tree, folder: "Applications", name: "Sketchbook", identifier: "com.example.sketchbook", version: "3.2")

        let apps = store(tree).apps()

        #expect(apps.count == 1)
        #expect(apps.first?.name == "Sketchbook")
        #expect(apps.first?.identifier == "com.example.sketchbook")
        #expect(apps.first?.version == "3.2")
    }

    @Test("Apple's own apps are never listed")
    func appleAppsAreExcluded() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try makeApp(tree, folder: "Applications", name: "Safari", identifier: "com.apple.Safari")
        try makeApp(tree, folder: "Applications", name: "Sketchbook", identifier: "com.example.sketchbook")

        // System Integrity Protection would refuse these, so offering them
        // would be a button that cannot work.
        #expect(store(tree).apps().map(\.identifier) == ["com.example.sketchbook"])
    }

    @Test("Attic never offers to uninstall itself")
    func ownAppIsExcluded() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try makeApp(tree, folder: "Applications", name: "Attic", identifier: InstalledAppStore.ownIdentifier)
        try makeApp(tree, folder: "Applications", name: "Sketchbook", identifier: "com.example.sketchbook")

        #expect(store(tree).apps().map(\.identifier) == ["com.example.sketchbook"])
    }

    @Test("Apps are listed in the order a person reads them")
    func appsAreSortedByName() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try makeApp(tree, folder: "Applications", name: "Zephyr", identifier: "com.example.zephyr")
        try makeApp(tree, folder: "Applications", name: "Anvil", identifier: "com.example.anvil")
        try makeApp(tree, folder: "Applications", name: "item10", identifier: "com.example.ten")
        try makeApp(tree, folder: "Applications", name: "item2", identifier: "com.example.two")

        #expect(store(tree).apps().map(\.name) == ["Anvil", "item2", "item10", "Zephyr"])
    }

    @Test("A folder that is not an app bundle is ignored")
    func nonBundlesAreIgnored() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Applications/Notes.txt", bytes: 100)
        try tree.directory("Applications/Some Folder")
        try makeApp(tree, folder: "Applications", name: "Sketchbook", identifier: "com.example.sketchbook")

        #expect(store(tree).apps().count == 1)
    }
}

@Suite("What an app would take with it")
struct AppFootprintTests {

    private func makeApp(_ tree: FixtureTree, name: String, identifier: String) throws -> InstalledApp {
        let contents = try tree.directory("Applications/\(name).app/Contents")
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleName</key><string>\(name)</string>
            </dict></plist>
            """
        try plist.data(using: .utf8)!.write(to: contents.appending(path: "Info.plist"))
        try tree.file("Applications/\(name).app/Contents/MacOS/\(name)", bytes: 32_768)
        return InstalledApp(
            bundleURL: tree.root.appending(path: "Applications/\(name).app"),
            identifier: identifier,
            name: name,
            version: nil
        )
    }

    private func store(_ tree: FixtureTree, running: Set<String> = []) -> InstalledAppStore {
        InstalledAppStore(
            folders: [tree.root.appending(path: "Applications")],
            supportLocations: OrphanLocation.standard(home: tree.root),
            runningIdentifiers: { running }
        )
    }

    @Test("The footprint is the bundle plus everything saved under its identifier")
    func footprintCoversBothHalves() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let app = try makeApp(tree, name: "Sketchbook", identifier: "com.example.sketchbook")
        try tree.file("Library/Application Support/com.example.sketchbook/data.db", bytes: 65_536)
        try tree.file("Library/Caches/com.example.sketchbook/cache.bin", bytes: 16_384)
        try tree.file("Library/Preferences/com.example.sketchbook.plist", bytes: 4_096)

        let footprint = store(tree).footprint(for: app)

        #expect(footprint.bundleBytes >= 32_768)
        #expect(footprint.supportPaths.count == 3)
        #expect(footprint.supportBytes >= 85_000)
        #expect(footprint.totalBytes == footprint.bundleBytes + footprint.supportBytes)
        // The bundle is always first, so the list reads app-then-leftovers.
        #expect(footprint.everything.first == app.bundleURL)
    }

    @Test("Another app's files are never included")
    func neighbouringIdentifiersAreNotTouched() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let app = try makeApp(tree, name: "Bar", identifier: "com.example.bar")
        try tree.file("Library/Caches/com.example.bar/mine.bin", bytes: 8_192)
        // The trap: a longer identifier that starts with the same text.
        try tree.file("Library/Caches/com.example.barista/theirs.bin", bytes: 8_192)

        let footprint = store(tree).footprint(for: app)

        #expect(footprint.supportPaths.count == 1)
        #expect(footprint.supportPaths.first?.lastPathComponent == "com.example.bar")
    }

    @Test("Support files are ordered largest first")
    func supportPathsAreOrderedBySize() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let app = try makeApp(tree, name: "Sketchbook", identifier: "com.example.sketchbook")
        try tree.file("Library/Caches/com.example.sketchbook/small.bin", bytes: 4_096)
        try tree.file("Library/Application Support/com.example.sketchbook/big.bin", bytes: 262_144)

        let footprint = store(tree).footprint(for: app)

        // So the one worth knowing about is the one you read first.
        #expect(footprint.supportPaths.first?.path.contains("Application Support") == true)
    }

    @Test("A running app is reported as running")
    func runningAppsAreFlagged() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let app = try makeApp(tree, name: "Sketchbook", identifier: "com.example.sketchbook")

        // Trashing a running app leaves a process with no files underneath it.
        #expect(store(tree, running: ["com.example.sketchbook"]).footprint(for: app).isRunning)
        #expect(store(tree, running: []).footprint(for: app).isRunning == false)
    }

    @Test("An app that saved nothing elsewhere is still removable")
    func appWithNoSupportFiles() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let app = try makeApp(tree, name: "Tiny", identifier: "com.example.tiny")

        let footprint = store(tree).footprint(for: app)

        #expect(footprint.supportPaths.isEmpty)
        #expect(footprint.supportBytes == 0)
        #expect(footprint.totalBytes == footprint.bundleBytes)
    }
}

/// An uninstall goes through the same planner and executor as everything else,
/// which is the point: the same containment check, the same denylist, the same
/// receipt. These tests prove the plan it hands over is bounded correctly.
@Suite("Uninstall plans")
struct UninstallPlanTests {

    private func footprint(_ tree: FixtureTree, supportPaths: [URL] = []) -> AppFootprint {
        AppFootprint(
            app: InstalledApp(
                bundleURL: tree.root.appending(path: "Applications/Sketchbook.app"),
                identifier: "com.example.sketchbook",
                name: "Sketchbook",
                version: "1.0"
            ),
            bundleBytes: 32_768,
            supportPaths: supportPaths,
            supportBytes: supportPaths.isEmpty ? 0 : 8_192,
            isRunning: false
        )
    }

    @Test("Each half is bounded by the folder it actually lives in")
    func rootsAreScopedToEachHalf() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let support = tree.root.appending(path: "Library/Caches/com.example.sketchbook")

        let inputs = InstalledAppStore.removalPlanInputs(
            for: footprint(tree, supportPaths: [support]),
            home: tree.root
        )

        let bundleRule = try #require(inputs.definitions.first { $0.id == "uninstall.bundle" })
        let supportRule = try #require(inputs.definitions.first { $0.id == "uninstall.support" })

        // The bundle rule reaches no further than the folder the app was
        // installed into; the support rule no further than ~/Library. Neither
        // gets a root that would let it wander.
        #expect(bundleRule.root.url.lastPathComponent == "Applications")
        #expect(supportRule.root.url.lastPathComponent == "Library")
        #expect(inputs.findings.count == 2)
    }

    @Test("An app with no leftovers produces one finding, not an empty second one")
    func noSupportMeansOneFinding() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let inputs = InstalledAppStore.removalPlanInputs(for: footprint(tree), home: tree.root)

        #expect(inputs.findings.count == 1)
        #expect(inputs.findings.first?.id.contains("uninstall.bundle") == true)
    }

    @Test("An uninstall is graded check-first, never safe")
    func uninstallIsNeverGradedSafe() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let support = tree.root.appending(path: "Library/Caches/com.example.sketchbook")

        let inputs = InstalledAppStore.removalPlanInputs(
            for: footprint(tree, supportPaths: [support]),
            home: tree.root
        )

        // Removing an app is not a cache clear. It is never part of a bulk
        // action, and it always wants reading first.
        for finding in inputs.findings {
            #expect(finding.grade == .checkFirst)
            #expect(finding.isSelectable)
        }
    }

    @Test("The plan explains what reinstalling does and does not bring back")
    func explanationIsHonestAboutWhatIsLost() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let finding = try #require(
            InstalledAppStore.removalPlanInputs(for: footprint(tree), home: tree.root).findings.first
        )

        #expect(finding.explanation.whatThisIs.contains("no uninstaller"))
        #expect(finding.explanation.whatStopsWorking.contains("will not launch"))
        // The part people need before they click: the app returns, its data does not.
        #expect(finding.explanation.doesItComeBack.contains("do not"))
    }

    @Test("The plan an uninstall hands over passes the ordinary gates")
    func planPassesTheUsualGates() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Applications/Sketchbook.app/Contents/MacOS/Sketchbook", bytes: 32_768)
        let support = try tree.file("Library/Caches/com.example.sketchbook/cache.bin", bytes: 8_192)

        let inputs = InstalledAppStore.removalPlanInputs(
            for: footprint(tree, supportPaths: [support.deletingLastPathComponent()]),
            home: tree.root
        )
        let plan = RemovalPlan.plan(for: inputs.findings, definitions: inputs.definitions)

        // Nothing refused, and both halves staged — the uninstaller is not a
        // second removal path, it is the same one with different inputs.
        #expect(plan.isSafeToExecute)
        #expect(plan.refusals.isEmpty)
        #expect(plan.trashOperations.count == 2)
    }
}
