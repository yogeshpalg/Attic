import Testing
import Foundation
@testable import Untitled_Project

/// Invariant 11. The view model is what turns a stream of events into the list a
/// person reads, so its ordering and its totals are user-facing behaviour. These
/// tests drive the real scan loop against fixture rules through the injected
/// `DefinitionStore`, rather than poking at state directly — the event handling is
/// part of what is being checked.
@Suite("Scan model")
@MainActor
struct ScanModelTests {

    private func scan(_ definitions: [RuleDefinition]) async throws -> ScanModel {
        try await scannedModel(definitions)
    }

    @Test("Staleness is ranked before size")
    func stalenessOutranksSize() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        // A large folder used last week, and a small one untouched for a year.
        // Size tells you where the bytes are; staleness tells you which ones you
        // will not miss, so the small stale one has to come first.
        try tree.file("BigAndRecent/build.o", bytes: 200_000)
        try tree.file("SmallAndStale/build.o", bytes: 4096)
        try tree.setModified(tree.root.appending(path: "BigAndRecent/build.o"), daysAgo: 5)
        try tree.setModified(tree.root.appending(path: "BigAndRecent"), daysAgo: 5)
        try tree.setModified(tree.root.appending(path: "SmallAndStale/build.o"), daysAgo: 300)
        try tree.setModified(tree.root.appending(path: "SmallAndStale"), daysAgo: 300)

        let model = try await scan([.fixture(root: tree.root)])

        #expect(model.findings(in: nil).map(\.displayName) == ["SmallAndStale", "BigAndRecent"])
    }

    @Test("Equally stale items are ranked by size")
    func equalStalenessFallsBackToSize() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Smaller/build.o", bytes: 4096)
        try tree.file("Larger/build.o", bytes: 200_000)

        // One shared timestamp, so the date comparison cannot break the tie.
        let shared = Date(timeIntervalSinceNow: -50 * 86_400)
        for path in ["Smaller/build.o", "Smaller", "Larger/build.o", "Larger"] {
            try FileManager.default.setAttributes(
                [.modificationDate: shared],
                ofItemAtPath: tree.root.appending(path: path).path
            )
        }

        let model = try await scan([.fixture(root: tree.root)])

        #expect(model.findings(in: nil).map(\.displayName) == ["Larger", "Smaller"])
    }

    @Test("Only categories with findings are present, in catalogue order")
    func categoriesPresentFollowsCatalogueOrder() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("caches/blob.bin")
        try tree.file("xcode/blob.bin")

        let model = try await scan([
            .fixture(
                id: "rule.xcode",
                category: .developerXcode,
                root: tree.root.appending(path: "xcode"),
                match: .wholeRoot,
                grouping: .single
            ),
            .fixture(
                id: "rule.caches",
                category: .cachesAndLogs,
                root: tree.root.appending(path: "caches"),
                match: .wholeRoot,
                grouping: .single
            ),
        ])

        // `Category.allCases` order, not discovery order — the scan is concurrent,
        // so discovery order is not stable.
        #expect(model.categoriesPresent == [.cachesAndLogs, .developerXcode])
    }

    @Test("Totals are reported overall and per category")
    func totalsAreSummed() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("caches/blob.bin")
        try tree.file("xcode/blob.bin")

        let model = try await scan([
            .fixture(
                id: "rule.xcode",
                category: .developerXcode,
                root: tree.root.appending(path: "xcode"),
                match: .wholeRoot,
                grouping: .single
            ),
            .fixture(
                id: "rule.caches",
                category: .cachesAndLogs,
                root: tree.root.appending(path: "caches"),
                match: .wholeRoot,
                grouping: .single
            ),
        ])

        #expect(model.findings.count == 2)
        #expect(model.totalFound == model.total(in: .developerXcode) + model.total(in: .cachesAndLogs))
        #expect(model.total(in: nil) == model.totalFound)
        #expect(model.total(in: .backups) == 0)
        #expect(model.findings(in: .cachesAndLogs).count == 1)
    }

    @Test("What was found and what can be acted on are separate figures")
    func selectableTotalExcludesWhatIsOnlyShown() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("offered/blob.bin")
        try tree.file("shown/blob.bin")

        let model = try await scan([
            .fixture(
                id: "rule.offered",
                root: tree.root.appending(path: "offered"),
                match: .wholeRoot,
                grouping: .single
            ),
            .fixture(
                id: "rule.shown",
                root: tree.root.appending(path: "shown"),
                match: .wholeRoot,
                grouping: .single,
                status: .detectOnly
            ),
        ])

        let offered = try #require(model.findings.first { $0.ruleID == "rule.offered" })

        // Both are found and reported; only one is on offer. Presenting the found
        // total as reclaimable space would promise bytes Attic will not touch.
        #expect(model.findings.count == 2)
        #expect(model.selectableTotal(in: nil) == offered.allocatedSize)
        #expect(model.selectableTotal(in: nil) < model.totalFound)
    }

    @Test("A rule with nothing to offer contributes nothing to either figure")
    func selectableTotalIsZeroWhenNothingIsOffered() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("kept/device.img")

        let model = try await scan([
            .fixture(root: tree.root, match: .wholeRoot, grouping: .single, grade: .keep)
        ])

        #expect(model.totalFound > 0)
        #expect(model.selectableTotal(in: nil) == 0)
        #expect(model.selectableTotal(in: .developerXcode) == 0)
    }

    @Test("Banners name the rule rather than its identifier")
    func ruleNamesResolveForBanners() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let model = try await scan([
            .fixture(
                id: "xcode.documentation-cache",
                root: tree.root.appending(path: "never-created"),
                match: .wholeRoot
            )
        ])

        let skipped = try #require(model.unavailable.first)

        // "xcode.documentation-cache" is a thing in the source. The person
        // reading the banner needs the name the rule shows everywhere else.
        #expect(skipped.ruleID == "xcode.documentation-cache")
        #expect(model.ruleName(skipped.ruleID) == "Fixture")
    }

    @Test("An unknown rule falls back to its identifier rather than showing nothing")
    func unknownRuleFallsBackToItsIdentifier() {
        let model = ScanModel(store: DefinitionStore(source: FixedSource(rules: [])))

        // Reaching this means an event named a rule the catalogue does not have,
        // which is a bug — but a blank banner would hide it.
        #expect(model.ruleName("rule.that.never.ran") == "rule.that.never.ran")
    }

    @Test("A rule that found nothing reports why, and does not inflate the total")
    func unavailableRuleIsSurfaced() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let model = try await scan([
            .fixture(root: tree.root.appending(path: "never-created"), match: .wholeRoot)
        ])

        #expect(model.findings.isEmpty)
        #expect(model.totalFound == 0)
        #expect(model.unavailable.map(\.reason) == [.rootMissing])
        #expect(model.phase == .review)
    }

    @Test("What a rule withheld reaches the model")
    func withheldReachesTheModel() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("LiveProject/build.o")

        let model = try await scan([
            .fixture(root: tree.root, retention: .excludeModifiedWithin(days: 7))
        ])

        #expect(model.findings.isEmpty)
        #expect(model.withheld.count == 1)
        #expect(model.withheld.first?.reason == .touchedRecently(days: 7))
    }

    @Test("A rejected path reaches the model rather than being logged and forgotten")
    func rejectionReachesTheModel() async throws {
        // A rule rooted at a denylisted path. Nothing is enumerated: the root gate
        // fires first, so the real Documents folder is never read.
        let documents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")

        let model = try await scan([.fixture(root: documents)])

        #expect(model.findings.isEmpty)
        #expect(model.rejections.map(\.reason) == [.denylisted])
    }

    @Test("Every rule that began also completed")
    func activeRulesDrainOnCompletion() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")

        let model = try await scan([.fixture(root: tree.root)])

        #expect(model.activeRuleIDs.isEmpty)
    }

    @Test("Free space is recorded before the scan starts")
    func spaceIsRecordedAtStart() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")

        let model = try await scan([.fixture(root: tree.root)])

        #expect(model.spaceAtStart != nil)
    }

    @Test("Cancelling a finished scan keeps the results on screen")
    func cancellingAfterReviewKeepsFindings() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")

        let model = try await scan([.fixture(root: tree.root)])
        model.cancelScan()

        #expect(model.phase == .review)
        #expect(model.findings.isEmpty == false)
    }

    @Test("Cancelling with nothing found returns to the first-run state")
    func cancellingWithNothingFoundReturnsToFirstRun() {
        let model = ScanModel(store: DefinitionStore(source: FixedSource(rules: [])))

        model.cancelScan()

        #expect(model.phase == .firstRun)
    }
}

/// Invariant 12. The figures can be checked against the system's own accounting.
/// Nothing in the app shells out — this only builds the text of a command for the
/// user to run themselves.
@Suite("Verification command")
@MainActor
struct VerificationCommandTests {

    @Test("With nothing found there is nothing to verify")
    func emptyScanHasNoCommand() {
        let model = ScanModel(store: DefinitionStore(source: FixedSource(rules: [])))

        #expect(model.verificationCommand(for: nil).isEmpty)
    }

    @Test("Every path is quoted, because these paths contain spaces")
    func pathsAreQuoted() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Project With Spaces/build.o")

        let model = try await scannedModel([.fixture(root: tree.root)])

        // Checked against the path the model actually holds: directory
        // enumeration hands back the canonical `/private/var/…` spelling of the
        // fixture's `/var/…` root, and the quoting is what is under test.
        let found = try #require(model.findings.first?.paths.first).path
        let command = model.verificationCommand(for: nil)

        #expect(command.hasPrefix("du -sch"))
        #expect(found.hasSuffix("Project With Spaces"))
        #expect(command.contains("'\(found)'"))
    }
}

/// A store source that hands back exactly the rules it was given.
private struct FixedSource: DefinitionSource {
    let rules: [RuleDefinition]

    func load() throws -> [RuleDefinition] { rules }
}

/// Runs a scan to completion, or gives up rather than hanging the suite. The scan
/// is driven through its real event loop, so the model's own event handling is part
/// of what every test here exercises.
@MainActor
private func scannedModel(_ definitions: [RuleDefinition]) async throws -> ScanModel {
    let model = ScanModel(store: DefinitionStore(source: FixedSource(rules: definitions)))
    // Fixtures are kilobytes, and the shipping floor hides anything under 5 MB.
    // These suites are about everything except that, so they opt out of it.
    model.sizeFloor = .everything
    model.startScan()

    for _ in 0..<600 {
        if model.phase == .review { return model }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the scan did not finish within six seconds")
    return model
}
