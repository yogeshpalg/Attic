import Testing
import Foundation
@testable import Untitled_Project

/// Invariant 16. Removing anything is the user's act, never the app's. Nothing is
/// ticked for them, a bulk action never reaches past what is graded safe, and a
/// row Attic cannot act on cannot be ticked at all — so the interface can never
/// offer a selection the planner would refuse.
@Suite("Selection and removal")
@MainActor
struct SelectionTests {

    /// A trash closure that records instead of moving, so nothing here reaches
    /// the real Trash.
    private final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ url: URL) -> URL? {
            lock.withLock { paths.append(url.path) }
            return URL(fileURLWithPath: "/private/tmp/trash").appending(path: url.lastPathComponent)
        }

        var recorded: [String] { lock.withLock { paths } }
    }

    private func scanned(
        _ definitions: [RuleDefinition], trash: TrashLog
    ) async throws -> ScanModel {
        let model = ScanModel(
            store: DefinitionStore(source: RuleSource(rules: definitions)),
            trash: { trash.record($0) }
        )
        // Fixtures are kilobytes; the shipping floor hides anything under 5 MB.
        model.sizeFloor = .everything
        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { return model }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the scan did not finish within six seconds")
        return model
    }

    @Test("A fresh scan has nothing selected")
    func nothingIsPreselected() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let model = try await scanned([.fixture(root: tree.root)], trash: log)

        #expect(model.findings.isEmpty == false)
        #expect(model.selection.isEmpty)
        #expect(model.selectedBytes == 0)
    }

    @Test("Ticking and unticking a row is symmetric")
    func togglingIsSymmetric() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let model = try await scanned([.fixture(root: tree.root)], trash: log)
        let finding = try #require(model.findings.first)

        model.toggle(finding)
        #expect(model.isSelected(finding))
        #expect(model.selectedBytes == finding.allocatedSize)

        model.toggle(finding)
        #expect(model.isSelected(finding) == false)
        #expect(model.selectedBytes == 0)
    }

    @Test("A row Attic will not act on cannot be ticked")
    func unofferedRowsCannotBeSelected() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("snapshot.plist")
        let log = TrashLog()

        let model = try await scanned(
            [.fixture(root: tree.root, match: .wholeRoot, grouping: .single, status: .detectOnly)],
            trash: log
        )
        let finding = try #require(model.findings.first)

        model.toggle(finding)

        #expect(finding.isSelectable == false)
        #expect(model.selection.isEmpty)
    }

    @Test("Selecting safe items leaves check-first items alone")
    func bulkSelectionStopsAtSafe() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("safe/blob.bin")
        try tree.file("careful/blob.bin")
        let log = TrashLog()

        let model = try await scanned([
            .fixture(
                id: "rule.safe", root: tree.root.appending(path: "safe"),
                match: .wholeRoot, grouping: .single, grade: .safe
            ),
            .fixture(
                id: "rule.careful", root: tree.root.appending(path: "careful"),
                match: .wholeRoot, grouping: .single, grade: .checkFirst
            ),
        ], trash: log)

        model.selectSafe(in: nil)

        // `checkFirst` is the grade for things that cost a rebuild or a download.
        // A bulk action never includes them.
        let selected = model.selectedFindings
        #expect(selected.count == 1)
        #expect(selected.first?.ruleID == "rule.safe")
    }

    @Test("The safe button unticks what it ticked, and nothing else")
    func safeSelectionTogglesBackOff() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("safe/blob.bin")
        try tree.file("also-safe/blob.bin")
        try tree.file("careful/blob.bin")
        let log = TrashLog()

        let model = try await scanned([
            .fixture(
                id: "rule.safe", root: tree.root.appending(path: "safe"),
                match: .wholeRoot, grouping: .single, grade: .safe
            ),
            .fixture(
                id: "rule.also-safe", root: tree.root.appending(path: "also-safe"),
                match: .wholeRoot, grouping: .single, grade: .safe
            ),
            .fixture(
                id: "rule.careful", root: tree.root.appending(path: "careful"),
                match: .wholeRoot, grouping: .single, grade: .checkFirst
            ),
        ], trash: log)

        // Ticked by hand, so it is not the button's to remove.
        let careful = try #require(model.findings.first { $0.ruleID == "rule.careful" })
        model.toggle(careful)

        #expect(model.hasSelectedAllSafe(in: nil) == false)
        model.toggleSafeSelection(in: nil)
        #expect(model.hasSelectedAllSafe(in: nil))
        #expect(model.selectedFindings.count == 3)

        // Second press: the two safe rows go, the hand-ticked one stays. A
        // button that cleared the whole list here would throw away a choice
        // somebody made deliberately.
        model.toggleSafeSelection(in: nil)
        #expect(model.hasSelectedAllSafe(in: nil) == false)
        #expect(model.selectedFindings.map(\.ruleID) == ["rule.careful"])
    }

    @Test("A partly ticked list fills up rather than emptying")
    func partialSafeSelectionFillsUp() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("one/blob.bin")
        try tree.file("two/blob.bin")
        let log = TrashLog()

        let model = try await scanned([
            .fixture(
                id: "rule.one", root: tree.root.appending(path: "one"),
                match: .wholeRoot, grouping: .single, grade: .safe
            ),
            .fixture(
                id: "rule.two", root: tree.root.appending(path: "two"),
                match: .wholeRoot, grouping: .single, grade: .safe
            ),
        ], trash: log)

        model.toggle(try #require(model.findings.first))
        // One of two ticked is not "all", so the button ticks the rest instead
        // of unticking the one that was already on.
        model.toggleSafeSelection(in: nil)

        #expect(model.selectedFindings.count == 2)
    }

    @Test("With nothing safe in view the button does nothing")
    func noSafeItemsMeansNoAction() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("careful/blob.bin")
        let log = TrashLog()

        let model = try await scanned([
            .fixture(
                id: "rule.careful", root: tree.root.appending(path: "careful"),
                match: .wholeRoot, grouping: .single, grade: .checkFirst
            ),
        ], trash: log)

        // False rather than true: "all of nothing is selected" would make the
        // button read "Deselect safe" over an empty list.
        #expect(model.hasSelectedAllSafe(in: nil) == false)
        #expect(model.safeFindings(in: nil).isEmpty)

        model.toggleSafeSelection(in: nil)
        #expect(model.selection.isEmpty)
    }

    @Test("A new scan clears the previous selection and receipt")
    func rescanningStartsClean() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let model = try await scanned([.fixture(root: tree.root)], trash: log)
        model.toggle(try #require(model.findings.first))
        #expect(model.selection.isEmpty == false)

        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.selection.isEmpty)
        #expect(model.receipt == nil)
    }

    @Test("Removing what is ticked trashes it and takes it off the list")
    func removalTrashesAndClearsTheRow() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let model = try await scanned([.fixture(root: tree.root)], trash: log)
        let finding = try #require(model.findings.first)
        model.toggle(finding)
        model.removeSelected()

        let receipt = try #require(model.receipt)
        #expect(receipt.wasAbandoned == false)
        #expect(receipt.trashedCount == 1)
        #expect(log.recorded == finding.paths.map(\.path))
        #expect(finding.paths.first?.path.hasSuffix("ProjectA") == true)
        #expect(file.path.hasSuffix("build.o"))
        // The row is gone because the thing it described is gone.
        #expect(model.findings.isEmpty)
        #expect(model.selection.isEmpty)
    }

    @Test("Removing nothing does nothing")
    func removingWithEmptySelectionIsANoOp() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let model = try await scanned([.fixture(root: tree.root)], trash: log)
        model.removeSelected()

        #expect(model.receipt == nil)
        #expect(log.recorded.isEmpty)
        #expect(model.findings.count == 1)
    }

    @Test("A row whose removal failed stays on the list")
    func failedRemovalKeepsTheRow() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")

        struct Denied: LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }

        let model = ScanModel(
            store: DefinitionStore(source: RuleSource(rules: [.fixture(root: tree.root)])),
            trash: { _ in throw Denied() }
        )
        model.sizeFloor = .everything
        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        model.toggle(try #require(model.findings.first))
        model.removeSelected()

        let receipt = try #require(model.receipt)
        // Still on disk, so still on the list. Clearing the row here would tell
        // the user their space came back when it did not.
        #expect(receipt.trashedCount == 0)
        #expect(receipt.problems.count == 1)
        #expect(model.findings.count == 1)
        #expect(model.selection.count == 1)
    }

    @Test("A receipt can be dismissed")
    func receiptCanBeDismissed() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let model = try await scanned([.fixture(root: tree.root)], trash: log)
        model.toggle(try #require(model.findings.first))
        model.removeSelected()
        #expect(model.receipt != nil)

        model.dismissReceipt()

        #expect(model.receipt == nil)
    }
}

private struct RuleSource: DefinitionSource {
    let rules: [RuleDefinition]

    func load() throws -> [RuleDefinition] { rules }
}
