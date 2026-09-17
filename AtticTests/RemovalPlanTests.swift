import Testing
import Foundation
@testable import Attic

/// Invariant 7. The plan re-verifies everything rather than trusting the scan. A
/// DerivedData scan can be minutes old by the time someone finishes reading the
/// explanations, and Xcode will have rewritten it — so containment is re-checked
/// against the compiled catalogue, the denylist is consulted again, and sizes are
/// re-measured. Nothing here performs anything; the plan *is* the dry run.
@Suite("Removal planning")
struct RemovalPlanTests {

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    @Test("A path inside its rule's root is staged for the Trash at its current size")
    func containedPathIsStaged() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")
        let fresh = DiskMeasure.measure(file).allocatedSize

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [file], allocatedSize: fresh)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.trash(url: file, bytes: fresh)])
        #expect(plan.bytesStaged == fresh)
        #expect(plan.isSafeToExecute)
    }

    @Test("A path outside its rule's root is refused")
    func escapedPathIsRefused() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let scanned = try tree.directory("scanned")
        let outside = try tree.file("elsewhere/secret.key")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [outside])],
            definitions: [.fixture(root: scanned)]
        )

        #expect(plan.operations == [.refuse(path: outside.path, reason: .outsideDeclaredRoot)])
        #expect(plan.isSafeToExecute == false)
        #expect(plan.trashOperations.isEmpty)
        #expect(plan.bytesStaged == 0)
    }

    @Test("A denylisted path is refused even when its rule's root contains it")
    func denylistedPathIsRefused() {
        // Nothing is read from disk: the denylist gate fires before the existence
        // check, so this never touches the real Documents folder.
        let documents = home.appending(path: "Documents")
        let path = documents.appending(path: "tax-return.pdf")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [path])],
            definitions: [.fixture(root: documents)]
        )

        #expect(plan.operations == [.refuse(path: path.path, reason: .denylisted)])
        #expect(plan.isSafeToExecute == false)
    }

    @Test("A finding with no catalogue entry is refused outright")
    func findingWithoutRuleIsRefused() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")

        // No declared root means containment cannot be verified at all.
        let plan = RemovalPlan.plan(for: [.fixture(paths: [file])], definitions: [])

        #expect(plan.operations == [.refuse(path: file.path, reason: .outsideDeclaredRoot)])
        #expect(plan.isSafeToExecute == false)
    }

    @Test("A path that vanished between the scan and the plan is reported as missing")
    func vanishedPathIsMissing() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let gone = tree.root.appending(path: "ProjectA")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [gone])],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.missing(path: gone.path)])
        #expect(plan.isSafeToExecute)
        #expect(plan.bytesStaged == 0)
    }

    @Test("A path whose size changed is still trashed, at its real size")
    func resizedPathIsStillTrashed() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")
        let fresh = DiskMeasure.measure(file).allocatedSize
        let stale: Int64 = 999_999

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [file], allocatedSize: stale)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.resized(url: file, scanned: stale, bytes: fresh)])

        // The gap this test used to pin: `resized` was excluded from the trash
        // operations while its bytes still counted toward the staged figure, so
        // the dry run described an item that would not move — while the
        // executor, which re-measures and moves every path, moved it anyway.
        // The plan now says what the executor does.
        #expect(plan.trashOperations.count == 1)
        #expect(plan.resizedOperations.count == 1)
        #expect(plan.bytesStaged == fresh)
        #expect(plan.isSafeToExecute)

        // A size change is not grounds to refuse something somebody chose, so
        // the log reads as a removal — with the scan's figure alongside, because
        // the difference is theirs to see.
        #expect(plan.dryRunLog.hasPrefix("TRASH"))
        #expect(plan.dryRunLog.contains("scan said"))
    }
}

/// Invariant 8. Attic never escalates and never acts on what it only knows how to
/// show. Anything it cannot itself perform degrades to Reveal in Finder rather than
/// being dropped from the plan, so the user can still deal with it by hand.
@Suite("Planning what Attic will not do")
struct RevealDegradationTests {

    @Test("A reveal-only finding plans one reveal per path")
    func revealOnlyPlansReveals() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let one = try tree.file("one.bin")
        let two = try tree.file("two.bin")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [one, two], action: .revealOnly)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.reveal(url: one), .reveal(url: two)])
        #expect(plan.bytesStaged == 0)
    }

    @Test("A keep-graded finding reaching the planner degrades to reveal")
    func keepGradeDegradesToReveal() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("device.img")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [file], grade: .keep)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.reveal(url: file)])
    }

    @Test("A detect-only finding reaching the planner degrades to reveal")
    func detectOnlyDegradesToReveal() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("snapshot.plist")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [file], status: .detectOnly)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.reveal(url: file)])
    }

    @Test("An administrator finding degrades to reveal rather than escalating")
    func administratorDegradesToReveal() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("runtime.dmg")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [file], privilege: .administrator)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.reveal(url: file)])
    }

    @Test("A command finding plans the command once, not once per path")
    func commandPlansOneRun() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let one = try tree.file("one.bin")
        let two = try tree.file("two.bin")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [one, two], action: .command(.brewCleanup))],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.operations == [.run(.brewCleanup)])
        #expect(plan.bytesStaged == 0)
    }
}

/// The dry-run log is the record of what would have happened. Every line names its
/// operation first so the log is scannable, and every refusal says why.
@Suite("Dry-run log")
struct DryRunLogTests {

    @Test("Each operation logs under its own verb")
    func everyOperationHasAVerb() {
        let url = URL(fileURLWithPath: "/private/tmp/attic/item")

        #expect(PlannedOperation.trash(url: url, bytes: 4096).loggedLine.hasPrefix("TRASH"))
        #expect(PlannedOperation.run(.brewCleanup).loggedLine.hasPrefix("RUN"))
        #expect(PlannedOperation.reveal(url: url).loggedLine.hasPrefix("REVEAL"))
        #expect(PlannedOperation.missing(path: url.path).loggedLine.hasPrefix("MISSING"))
        // A resized path logs as a removal, because that is what happens to it.
        // The verb describes the operation; the scanned figure rides along so
        // the difference is visible rather than absorbed.
        let resized = PlannedOperation.resized(url: url, scanned: 1, bytes: 2).loggedLine
        #expect(resized.hasPrefix("TRASH"))
        #expect(resized.contains("scan said"))
    }

    @Test("A refusal logs the reason alongside the path")
    func refusalLogsItsReason() {
        let line = PlannedOperation.refuse(path: "/private/tmp/x", reason: .denylisted).loggedLine

        #expect(line.hasPrefix("REFUSE"))
        #expect(line.contains(RejectionReason.denylisted.message))
        #expect(line.contains("/private/tmp/x"))
    }

    @Test("A command logs the exact text that would run")
    func commandLogsItsDisplayForm() {
        #expect(
            PlannedOperation.run(.simctlDeletePreviews).loggedLine
                .contains("xcrun simctl --set previews delete all")
        )
    }

    @Test("The log carries one line per operation")
    func logHasOneLinePerOperation() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let one = try tree.file("one.bin")
        let two = try tree.file("two.bin")

        let plan = RemovalPlan.plan(
            for: [.fixture(paths: [one, two], action: .revealOnly)],
            definitions: [.fixture(root: tree.root)]
        )

        #expect(plan.dryRunLog.split(separator: "\n").count == 2)
    }
}
