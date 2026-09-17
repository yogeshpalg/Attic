import Testing
import Foundation
@testable import Attic

/// Invariant 21. The lifetime counter records what Attic moved to the Trash,
/// which is not the same as what came back: the Trash sits on the disk until the
/// user empties it. A counter that claimed credit for space still occupied would
/// be the same kind of lie as a total that counts bytes nothing would remove.
@Suite("Lifetime counter")
struct TallyTests {

    /// Its own defaults domain, so no test writes to the real preferences.
    private func freshTally() -> (ReclaimedTally, UserDefaults) {
        let suite = "attic.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ReclaimedTally(defaults: defaults), defaults)
    }

    @Test("A fresh install has nothing to report")
    func freshInstallIsEmpty() {
        let (tally, _) = freshTally()

        #expect(tally.bytes == 0)
        #expect(tally.items == 0)
        // Not "0 bytes since today" — nothing at all, until something happens.
        #expect(tally.since == nil)
        #expect(tally.hasRecordedAnything == false)
    }

    @Test("A removal is added to the running total")
    func removalsAccumulate() {
        let (tally, _) = freshTally()

        tally.add(bytes: 5_000_000, items: 2)
        tally.add(bytes: 3_000_000, items: 1)

        #expect(tally.bytes == 8_000_000)
        #expect(tally.items == 3)
        #expect(tally.hasRecordedAnything)
    }

    @Test("The date is the first removal, not the most recent one")
    func dateMarksWhenCountingStarted() {
        let (tally, _) = freshTally()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let later = Date(timeIntervalSince1970: 2_000_000)

        tally.add(bytes: 1_000, items: 1, now: first)
        tally.add(bytes: 1_000, items: 1, now: later)

        // "12 items since 9 Jan" only makes sense if the date is the start.
        #expect(tally.since == first)
    }

    @Test("A removal that moved nothing is not recorded")
    func emptyRemovalsAreIgnored() {
        let (tally, _) = freshTally()

        tally.add(bytes: 0, items: 0)

        // An abandoned or wholly refused batch moved nothing, so it starts no
        // counter and sets no date.
        #expect(tally.hasRecordedAnything == false)
        #expect(tally.since == nil)
    }

    @Test("Resetting clears the figure, the count and the date together")
    func resetClearsEverything() {
        let (tally, _) = freshTally()
        tally.add(bytes: 9_000_000, items: 4)

        tally.reset()

        #expect(tally.bytes == 0)
        #expect(tally.items == 0)
        #expect(tally.since == nil)
        #expect(tally.hasRecordedAnything == false)
    }

    @Test("The total survives being read through a second instance")
    func totalPersists() {
        let (tally, defaults) = freshTally()
        tally.add(bytes: 4_096, items: 1)

        // What a relaunch sees.
        let reopened = ReclaimedTally(defaults: defaults)

        #expect(reopened.bytes == 4_096)
        #expect(reopened.items == 1)
    }

    @Test("An absurd total saturates rather than going negative")
    func totalSaturates() {
        let (tally, _) = freshTally()

        tally.add(bytes: Int64.max, items: 1)
        tally.add(bytes: Int64.max, items: 1)

        // A stuck counter is a better answer than one that wrapped into a
        // negative number of bytes.
        #expect(tally.bytes > 0)
        #expect(tally.items == 2)
    }
}

/// The model's half: only what actually moved is counted, and the figure the
/// interface reads updates the moment it happens.
@Suite("Counting removals")
@MainActor
struct TallyReportingTests {

    private final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ url: URL) -> URL? {
            lock.withLock { paths.append(url.path) }
            return URL(fileURLWithPath: "/private/tmp/trash").appending(path: url.lastPathComponent)
        }
    }

    private func scanned(_ tree: FixtureTree, tally: ReclaimedTally) async throws -> ScanModel {
        let log = TrashLog()
        let model = ScanModel(
            store: DefinitionStore(source: OneRule(root: tree.root)),
            trash: { log.record($0) },
            tally: tally
        )
        model.sizeFloor = .everything
        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { return model }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the scan did not finish within six seconds")
        return model
    }

    @Test("Moving something to the Trash raises the lifetime figure")
    func removalRaisesTheTotal() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o", bytes: 8192)
        let defaults = UserDefaults(suiteName: "attic.tests.\(UUID().uuidString)")!

        let model = try await scanned(tree, tally: ReclaimedTally(defaults: defaults))
        #expect(model.lifetimeReclaimed == 0)

        model.toggle(try #require(model.findings.first))
        model.removeSelected()

        #expect(model.lifetimeReclaimed >= 8192)
        #expect(model.lifetimeItems == 1)
        #expect(model.lifetimeSince != nil)
    }

    @Test("A failed removal adds nothing")
    func failedRemovalAddsNothing() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o", bytes: 8192)

        struct Denied: LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }

        let defaults = UserDefaults(suiteName: "attic.tests.\(UUID().uuidString)")!
        let model = ScanModel(
            store: DefinitionStore(source: OneRule(root: tree.root)),
            trash: { _ in throw Denied() },
            tally: ReclaimedTally(defaults: defaults)
        )
        model.sizeFloor = .everything
        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        model.toggle(try #require(model.findings.first))
        model.removeSelected()

        // Nothing moved, so nothing is claimed.
        #expect(model.lifetimeReclaimed == 0)
        #expect(model.lifetimeItems == 0)
    }

    @Test("Resetting puts the figure back to nothing")
    func resetClearsTheModelFigure() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o", bytes: 8192)
        let defaults = UserDefaults(suiteName: "attic.tests.\(UUID().uuidString)")!

        let model = try await scanned(tree, tally: ReclaimedTally(defaults: defaults))
        model.toggle(try #require(model.findings.first))
        model.removeSelected()
        #expect(model.lifetimeReclaimed > 0)

        model.resetLifetimeTotal()

        #expect(model.lifetimeReclaimed == 0)
        #expect(model.lifetimeItems == 0)
        #expect(model.lifetimeSince == nil)
    }
}

private struct OneRule: DefinitionSource {
    let root: URL

    func load() throws -> [RuleDefinition] { [.fixture(root: root)] }
}
