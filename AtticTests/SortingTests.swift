import Testing
import Foundation
@testable import Untitled_Project

/// Invariant 19. The list is ordered and filtered for readability, and neither
/// changes what was found. A size floor keeps forty 4 KB rows from burying the
/// 217 MB one — but what it hides is counted, reported, and still in the total,
/// because a hidden row and a row that was never found must not look alike.
@Suite("Sorting and the size floor")
@MainActor
struct SortingTests {

    private func model(_ findings: [Finding]) -> ScanModel {
        let model = ScanModel(store: DefinitionStore(source: EmptySource()))
        model.adopt(findings)
        return model
    }

    private func finding(
        _ name: String, bytes: Int64, files: Int = 1, daysAgo: Double? = nil
    ) -> Finding {
        .fixture(
            id: "rule.\(name)",
            displayName: name,
            paths: [URL(fileURLWithPath: "/private/tmp/\(name)")],
            fileCount: files,
            allocatedSize: bytes,
            lastUsed: daysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) }
        )
    }

    @Test("By default the longest unused comes first, whatever its size")
    func stalestFirstIsTheDefault() {
        let subject = model([
            finding("BigAndRecent", bytes: 900_000_000, daysAgo: 2),
            finding("SmallAndStale", bytes: 10_000_000, daysAgo: 400),
        ])

        #expect(subject.sortOrder == .stalestFirst)
        #expect(subject.findings(in: nil).map(\.displayName) == ["SmallAndStale", "BigAndRecent"])
    }

    @Test("Largest and smallest first are exact reverses")
    func sizeOrdersAreReverses() {
        let subject = model([
            finding("Middle", bytes: 50_000_000),
            finding("Largest", bytes: 900_000_000),
            finding("Smallest", bytes: 10_000_000),
        ])

        subject.sortOrder = .largestFirst
        #expect(subject.findings(in: nil).map(\.displayName) == ["Largest", "Middle", "Smallest"])

        subject.sortOrder = .smallestFirst
        #expect(subject.findings(in: nil).map(\.displayName) == ["Smallest", "Middle", "Largest"])
    }

    @Test("Most files ranks by count, then by size")
    func mostFilesRanksByCount() {
        let subject = model([
            finding("Few", bytes: 900_000_000, files: 3),
            finding("Many", bytes: 10_000_000, files: 20_000),
        ])

        subject.sortOrder = .mostFiles

        #expect(subject.findings(in: nil).map(\.displayName) == ["Many", "Few"])
    }

    @Test("Name sorts the way a person reads, not by character code")
    func nameSortsNaturally() {
        let subject = model([
            finding("item10", bytes: 10_000_000),
            finding("item2", bytes: 10_000_000),
            finding("Apple", bytes: 10_000_000),
        ])

        subject.sortOrder = .name

        // `item2` before `item10`, and case is not what decides the order.
        #expect(subject.findings(in: nil).map(\.displayName) == ["Apple", "item2", "item10"])
    }

    @Test("Ties are broken predictably rather than left to chance")
    func tiesAreStable() {
        let subject = model([
            finding("Beta", bytes: 10_000_000),
            finding("Alpha", bytes: 10_000_000),
        ])

        subject.sortOrder = .largestFirst

        #expect(subject.findings(in: nil).map(\.displayName) == ["Alpha", "Beta"])
        #expect(subject.findings(in: nil).map(\.displayName) == subject.findings(in: nil).map(\.displayName))
    }

    @Test("The floor defaults to five megabytes, so kilobyte rows stay out of the way")
    func floorDefaultsToFiveMegabytes() {
        let subject = model([
            finding("Worthwhile", bytes: 217_000_000),
            finding("Tiny", bytes: 4_096),
            finding("AlsoTiny", bytes: 37_000),
        ])

        #expect(subject.sizeFloor == .fiveMegabytes)
        #expect(subject.findings(in: nil).map(\.displayName) == ["Worthwhile"])
    }

    @Test("What the floor hides is counted and reported, never dropped")
    func hiddenItemsAreReported() {
        let subject = model([
            finding("Worthwhile", bytes: 217_000_000),
            finding("Tiny", bytes: 4_096),
            finding("AlsoTiny", bytes: 37_000),
        ])

        let hidden = subject.hiddenByFloor(in: nil)

        #expect(hidden.count == 2)
        #expect(hidden.bytes == 41_096)
    }

    @Test("The total counts everything found, including what is not shown")
    func totalsIgnoreTheFloor() {
        let subject = model([
            finding("Worthwhile", bytes: 217_000_000),
            finding("Tiny", bytes: 4_096),
        ])

        // The floor decides what is worth showing. It must never quietly change
        // the headline figure, or the list and the total stop agreeing.
        #expect(subject.totalFound == 217_004_096)
        #expect(subject.total(in: nil) == 217_004_096)
        #expect(subject.selectableTotal(in: nil) == 217_004_096)
        #expect(subject.findings(in: nil).count == 1)
    }

    @Test("Showing everything brings the small items back")
    func floorCanBeLifted() {
        let subject = model([
            finding("Worthwhile", bytes: 217_000_000),
            finding("Tiny", bytes: 4_096),
        ])

        subject.sizeFloor = .everything

        #expect(subject.findings(in: nil).count == 2)
        #expect(subject.hiddenByFloor(in: nil).count == 0)
    }

    @Test("A bulk selection reaches only what is on screen")
    func bulkSelectionRespectsTheFloor() {
        let subject = model([
            finding("Worthwhile", bytes: 217_000_000),
            finding("Tiny", bytes: 4_096),
        ])

        subject.selectSafe(in: nil)

        // What you see is what you selected — picking up a hidden row would be
        // the app choosing something on the user's behalf.
        #expect(subject.selectedFindings.map(\.displayName) == ["Worthwhile"])
    }

    @Test("Raising the floor does not keep a hidden row selected")
    func raisingTheFloorClearsHiddenSelections() {
        let subject = model([
            finding("Worthwhile", bytes: 217_000_000),
            finding("Small", bytes: 2_000_000),
        ])

        subject.sizeFloor = .everything
        subject.selectSafe(in: nil)
        #expect(subject.selection.count == 2)

        subject.sizeFloor = .fiveMegabytes

        // Otherwise the footer would offer to remove something the list is not
        // showing, which is the one thing a confirmation dialog must never do.
        #expect(subject.selectedFindings.map(\.displayName) == ["Worthwhile"])
        #expect(subject.selectedBytes == 217_000_000)
    }
}

private struct EmptySource: DefinitionSource {
    func load() throws -> [RuleDefinition] { [] }
}
