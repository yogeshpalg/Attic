import Testing
import Foundation
@testable import Attic

/// Invariant 20. A number that is quietly too small is worse than no number.
/// Where a scan could not read part of what it measured, the figure is a floor,
/// and the finding carries that fact all the way to the row it is shown in.
@Suite("Understated sizes")
struct DenialTests {

    /// Makes a directory unreadable, and puts it back afterwards so the fixture
    /// can be torn down.
    private func withLockedDirectory(
        _ tree: FixtureTree, _ relative: String, _ body: () async throws -> Void
    ) async throws {
        let locked = tree.root.appending(path: relative)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
        }
        try await body()
    }

    @Test("A finding whose folder could not be read says so")
    func unreadableContentMarksTheFinding() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Project/readable.bin", bytes: 8192)
        try tree.file("Project/locked/secret.bin", bytes: 8192)

        try await withLockedDirectory(tree, "Project/locked") {
            let result = await ScanProbe.run([
                .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch)
            ])

            let finding = try #require(result.findings.first)
            #expect(finding.wasPartlyUnreadable)
            // What it could read is still reported: a floor, not nothing.
            #expect(finding.allocatedSize >= 8192)
        }
    }

    @Test("A finding that could be read in full claims nothing of the sort")
    func readableContentIsNotMarked() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Project/readable.bin", bytes: 8192)

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch)
        ])

        #expect(result.findings.first?.wasPartlyUnreadable == false)
    }

    @Test("Collapsed findings carry the denial from any part of the group")
    func groupedFindingsCarryTheDenial() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Fine/data.bin", bytes: 8192)
        try tree.file("Blocked/inner/secret.bin", bytes: 8192)

        try await withLockedDirectory(tree, "Blocked/inner") {
            let result = await ScanProbe.run([
                .fixture(root: tree.root, match: .immediateChildren, grouping: .single)
            ])

            // One finding covering both; one of them was unreadable, so the
            // total under it is a floor.
            #expect(result.findings.count == 1)
            #expect(result.findings.first?.wasPartlyUnreadable == true)
        }
    }

    @Test("A match that is only unreadable is kept rather than dropped")
    func whollyUnreadableMatchesSurvive() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Fine/data.bin", bytes: 8192)
        try tree.file("Blocked/inner/secret.bin", bytes: 8192)

        try await withLockedDirectory(tree, "Blocked/inner") {
            let result = await ScanProbe.run([
                .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch)
            ])

            // `Blocked` measures as nothing, because its only contents cannot
            // be read. A "0 bytes" row is not an offer, so it makes no finding
            // — but the rule says a folder could not be read, which is the part
            // that must never be silent.
            #expect(result.findings.map(\.displayName) == ["Fine"])
            #expect(result.unavailable == [.permissionDenied])
        }
    }

    @Test("A rule that could read nothing says so, rather than calling it empty")
    func whollyDeniedRuleReportsPermission() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("locked/secret.bin", bytes: 8192)

        try await withLockedDirectory(tree, "locked") {
            let result = await ScanProbe.run([
                .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch)
            ])

            // "The folder this looks in is empty" would be untrue, and silence
            // would hide a folder the user could unlock.
            #expect(result.findings.isEmpty)
            #expect(result.unavailable == [.permissionDenied])
        }
    }
}

@Suite("Reporting what could not be read")
@MainActor
struct DenialReportingTests {

    @Test("The model raises the flag when any finding is understated")
    func modelFlagsUnderstatedSizes() {
        let model = ScanModel(store: DefinitionStore(source: NoRules()))

        model.adopt([
            .fixture(id: "a", paths: [URL(fileURLWithPath: "/private/tmp/a")], allocatedSize: 10_000_000)
        ])
        #expect(model.someSizesAreUnderstated == false)

        var partial = Finding.fixture(
            id: "b", paths: [URL(fileURLWithPath: "/private/tmp/b")], allocatedSize: 10_000_000
        )
        partial.wasPartlyUnreadable = true
        model.adopt([partial])

        #expect(model.someSizesAreUnderstated)
    }

    @Test("Rules that found nothing are grouped by reason, not listed one by one")
    func unavailableRulesAreGrouped() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        // A catalogue covering tools most Macs do not have would otherwise fill
        // the banner with one line per absent tool.
        let model = ScanModel(store: DefinitionStore(source: ThreeMissingRules(root: tree.root)))
        model.sizeFloor = .everything
        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.unavailable.count == 3)

        let summary = model.unavailableSummary
        #expect(summary.count == 1)
        #expect(summary.first?.reason == .rootMissing)
        #expect(summary.first?.ruleNames.count == 3)
        // Named, and in a stable order, so the disclosure reads the same twice.
        #expect(summary.first?.ruleNames == ["Absent one", "Absent three", "Absent two"])
    }
}

private struct NoRules: DefinitionSource {
    func load() throws -> [RuleDefinition] { [] }
}

private struct ThreeMissingRules: DefinitionSource {
    let root: URL

    func load() throws -> [RuleDefinition] {
        [
            named("rule.one", "Absent one"),
            named("rule.two", "Absent two"),
            named("rule.three", "Absent three"),
        ]
    }

    private func named(_ id: String, _ name: String) -> RuleDefinition {
        var rule = RuleDefinition.fixture(id: id, root: root.appending(path: "never-created"))
        rule = RuleDefinition(
            id: rule.id,
            minAppVersion: rule.minAppVersion,
            category: rule.category,
            displayName: name,
            root: rule.root,
            match: .wholeRoot,
            exclude: rule.exclude,
            grouping: rule.grouping,
            retention: rule.retention,
            subtitleStyle: rule.subtitleStyle,
            applicability: rule.applicability,
            action: rule.action,
            privilege: rule.privilege,
            grade: rule.grade,
            status: rule.status,
            explanation: rule.explanation
        )
        return rule
    }
}

/// Invariant 21. Attic asks macOS whether it can read the disk, rather than
/// deducing it from a scan that came back short.
///
/// The distinction the probe has to get right is refused versus absent. They
/// arrive at the same `open(2)` failure and mean opposite things: refused is
/// "warn somebody", absent is "say nothing". Collapsing them either sends
/// people into System Settings for no reason or leaves every figure on screen
/// quietly understated.
@Suite("Full Disk Access is asked about, not inferred")
struct FullDiskAccessTests {

    @Test("A file this process can open reads as granted")
    func readableProbeIsGranted() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("probe.db", bytes: 16)

        #expect(FullDiskAccess.state(probing: tree.root.appending(path: "probe.db").path) == .granted)
    }

    @Test("A file the process is refused reads as denied")
    func refusedProbeIsDenied() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("probe.db", bytes: 16)

        let probe = tree.root.appending(path: "probe.db")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: probe.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: probe.path
            )
        }

        #expect(FullDiskAccess.state(probing: probe.path) == .denied)
    }

    @Test("A missing file is undetermined, never denied")
    func missingProbeIsUndetermined() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        // The whole point of reading errno. A Mac where the probe file does not
        // exist has told Attic nothing, and nothing must not be reported as a
        // permission problem: that is a wild goose chase through System Settings
        // for somebody whose access was fine all along.
        #expect(
            FullDiskAccess.state(probing: tree.root.appending(path: "absent.db").path)
                == .undetermined
        )
    }

    @Test("The pane link names the identifier this System Settings publishes")
    func settingsURLIsCurrent() throws {
        let url = try #require(FullDiskAccess.settingsURL)

        // `com.apple.preference.security` is the System Preferences name. A
        // stale identifier does not fail — it opens System Settings at the top
        // level and leaves somebody hunting the sidebar, which is indistinguishable
        // from the button being broken.
        #expect(url.absoluteString.contains("com.apple.settings.PrivacySecurity.extension"))
        #expect(url.absoluteString.contains("com.apple.preference.security") == false)
        #expect(url.absoluteString.contains("Privacy_AllFiles"))
    }

    @Test("The app says a grant needs a relaunch")
    func relaunchIsStated() {
        // macOS fixes what a process may read at launch, so a grant does nothing
        // for the running copy. Leaving that out is why somebody grants the
        // permission, sees identical floors, and concludes the app is broken.
        #expect(FullDiskAccess.relaunchNotice.localizedCaseInsensitiveContains("restart"))
    }
}

/// The model has to say the figures are floors from the moment they appear, not
/// once a rule happens to trip over a folder it cannot open.
@Suite("Denied access understates sizes before a scan proves it")
@MainActor
struct DiskAccessReportingTests {

    @Test("With access denied, the sizes are called floors with nothing scanned")
    func denialUnderstatesImmediately() {
        let model = ScanModel(diskAccess: { .denied })

        #expect(model.diskAccess == .denied)
        // No findings, no unavailable rules: on the old inference this read as
        // "everything here is accurate", which was the bug.
        #expect(model.findings.isEmpty)
        #expect(model.someSizesAreUnderstated)
    }

    @Test("With access granted, nothing is claimed to be understated")
    func grantedSaysNothing() {
        let model = ScanModel(diskAccess: { .granted })

        #expect(model.diskAccess == .granted)
        #expect(model.someSizesAreUnderstated == false)
    }

    @Test("An undetermined probe is not treated as a denial")
    func undeterminedIsQuiet() {
        let model = ScanModel(diskAccess: { .undetermined })
        #expect(model.someSizesAreUnderstated == false)
    }
}
