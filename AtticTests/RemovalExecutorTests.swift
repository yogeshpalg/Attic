import Testing
import Foundation
@testable import Attic

/// Invariant 15. This is the only code in Attic that can change the disk, so the
/// gates run a third time here — after the scan, after the plan, immediately
/// before the move. The scan and the plan are separated by however long someone
/// spends reading the explanations, and Xcode keeps writing while they read.
///
/// Every test drives the executor with an injected trash closure, so the suite
/// never touches the real Trash. The one exception is marked.
@Suite("Removal execution")
struct RemovalExecutorTests {

    /// Records what was asked of the Trash instead of moving anything.
    private final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ url: URL) -> URL? {
            lock.withLock { paths.append(url.path) }
            return URL(fileURLWithPath: "/private/tmp/trash").appending(path: url.lastPathComponent)
        }

        var recorded: [String] { lock.withLock { paths } }
    }

    @Test("A selected finding is moved to the Trash and reported with its size")
    func selectedFindingIsTrashed() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            trash: { log.record($0) }
        ).execute([.fixture(paths: [file], allocatedSize: DiskMeasure.measure(file).allocatedSize)])

        #expect(log.recorded == [file.path])
        #expect(receipt.trashedCount == 1)
        #expect(receipt.bytesTrashed > 0)
        #expect(receipt.problems.isEmpty)
        #expect(receipt.wasAbandoned == false)
    }

    @Test("A path that left its root between plan and removal is not touched")
    func pathOutsideRootIsNeverTouched() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let scanned = try tree.directory("scanned")
        let outside = try tree.file("elsewhere/secret.key")
        let log = TrashLog()

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: scanned)],
            trash: { log.record($0) }
        ).execute([.fixture(paths: [outside])])

        // Abandoned at planning, so the closure is never reached at all.
        #expect(log.recorded.isEmpty)
        #expect(receipt.wasAbandoned)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("A denylisted path is never touched")
    func denylistedPathIsNeverTouched() {
        let documents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")
        let log = TrashLog()

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: documents)],
            trash: { log.record($0) }
        ).execute([.fixture(paths: [documents.appending(path: "tax-return.pdf")])])

        #expect(log.recorded.isEmpty)
        #expect(receipt.wasAbandoned)
    }

    @Test("One bad path abandons the whole batch, including the good paths")
    func oneRefusalAbandonsEverything() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let scanned = try tree.directory("scanned")
        let good = try tree.file("scanned/build.o")
        let bad = try tree.file("elsewhere/secret.key")
        let log = TrashLog()

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: scanned)],
            trash: { log.record($0) }
        ).execute([
            .fixture(id: "good", paths: [good], allocatedSize: DiskMeasure.measure(good).allocatedSize),
            .fixture(id: "bad", paths: [bad]),
        ])

        // If one path in a batch turned out to be wrong, the scan behind it is
        // suspect, so nothing goes — not even the path that verified cleanly.
        #expect(receipt.wasAbandoned)
        #expect(log.recorded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: good.path))
    }

    @Test("A finding with no catalogue entry is never removed")
    func findingWithoutRuleIsNeverRemoved() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")
        let log = TrashLog()

        let receipt = RemovalExecutor(definitions: [], trash: { log.record($0) })
            .execute([.fixture(paths: [file])])

        #expect(receipt.wasAbandoned)
        #expect(log.recorded.isEmpty)
    }

    @Test("A path that vanished after the plan is reported, not treated as an error")
    func vanishedPathIsReported() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")
        let log = TrashLog()
        let definitions = [RuleDefinition.fixture(root: tree.root)]
        let findings = [Finding.fixture(paths: [file], allocatedSize: DiskMeasure.measure(file).allocatedSize)]

        // Gone between the plan and the move — the common case with DerivedData.
        let executor = RemovalExecutor(definitions: definitions, trash: { url in
            try FileManager.default.removeItem(at: url)
            return log.record(url)
        })
        try FileManager.default.removeItem(at: file)

        let receipt = executor.execute(findings)

        #expect(receipt.outcomes == [.vanished(path: file.path)])
        #expect(receipt.trashedCount == 0)
        #expect(receipt.problems.isEmpty)
    }

    @Test("A filesystem refusal is reported with what the system said")
    func failureCarriesItsMessage() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("ProjectA/build.o")

        struct Denied: LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            trash: { _ in throw Denied() }
        ).execute([.fixture(paths: [file], allocatedSize: DiskMeasure.measure(file).allocatedSize)])

        #expect(receipt.trashedCount == 0)
        #expect(receipt.problems.count == 1)
        #expect(receipt.problems.first == .failed(path: file.path, message: "Operation not permitted"))
        // Still on disk, and the receipt says so rather than claiming success.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A finding Attic will not act on is revealed, never removed")
    func unofferedFindingsAreRevealed() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("snapshot.plist")
        let log = TrashLog()

        for finding in [
            Finding.fixture(paths: [file], status: .detectOnly),
            Finding.fixture(paths: [file], grade: .keep),
            Finding.fixture(paths: [file], privilege: .administrator),
            Finding.fixture(paths: [file], action: .revealOnly),
        ] {
            let receipt = RemovalExecutor(
                definitions: [.fixture(root: tree.root)],
                trash: { log.record($0) }
            ).execute([finding])

            #expect(receipt.outcomes == [.revealed(path: file.path)])
        }

        #expect(log.recorded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A command finding runs its command and touches no files itself")
    func commandFindingsRunTheirCommand() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("previews/blob.bin")
        let log = TrashLog()

        // The runner is always injected here. A test that reached the real one
        // would run `simctl` against the machine it is running on — which is
        // exactly what the earlier version of this test did.
        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            trash: { log.record($0) },
            runner: CommandRunner { command in
                CommandResult(command: command, exitCode: 0, output: "")
            }
        ).execute([.fixture(paths: [file], action: .command(.simctlDeletePreviews))])

        #expect(receipt.outcomes == [.ran(command: .simctlDeletePreviews, output: "")])
        // Attic moves nothing for a command rule: the tool knows which of its
        // own files it still needs, and Attic does not.
        #expect(log.recorded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Every outcome logs under its own verb")
    func outcomesHaveVerbs() {
        let path = "/private/tmp/attic/item"

        #expect(RemovalOutcome.trashed(path: path, bytes: 4096, inTrashAt: nil).loggedLine.hasPrefix("TRASHED"))
        #expect(RemovalOutcome.revealed(path: path).loggedLine.hasPrefix("REVEALED"))
        #expect(RemovalOutcome.refused(path: path, reason: .denylisted).loggedLine.hasPrefix("REFUSED"))
        #expect(RemovalOutcome.vanished(path: path).loggedLine.hasPrefix("VANISHED"))
        #expect(RemovalOutcome.failed(path: path, message: "nope").loggedLine.hasPrefix("FAILED"))
    }

    @Test("Nothing selected removes nothing")
    func emptySelectionIsANoOp() {
        let log = TrashLog()

        let receipt = RemovalExecutor(definitions: [], trash: { log.record($0) }).execute([])

        #expect(receipt.outcomes.isEmpty)
        #expect(receipt.wasAbandoned == false)
        #expect(log.recorded.isEmpty)
    }

    @Test("Evicting a cloud copy reports the space without deleting the file")
    func evictionFreesSpaceWithoutDeleting() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("Documents/report.pages", bytes: 8192)
        let log = TrashLog()
        let evicted = TrashLog()

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            trash: { log.record($0) },
            evict: { _ = evicted.record($0) }
        ).execute([
            .fixture(
                paths: [file],
                allocatedSize: DiskMeasure.measure(file).allocatedSize,
                grade: .checkFirst,
                action: .evictCloudCopy
            )
        ])

        // Nothing goes to the Trash, because nothing is being deleted.
        #expect(log.recorded.isEmpty)
        #expect(evicted.recorded == [file.path])
        #expect(receipt.outcomes.count == 1)
        #expect(receipt.bytesTrashed >= 8192)
        #expect(receipt.problems.isEmpty)
    }

    @Test("An eviction outside the declared root is refused like any other removal")
    func evictionIsGatedToo() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let scanned = try tree.directory("scanned")
        let outside = try tree.file("elsewhere/private.pages")
        let evicted = TrashLog()

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: scanned)],
            evict: { _ = evicted.record($0) }
        ).execute([.fixture(paths: [outside], grade: .checkFirst, action: .evictCloudCopy)])

        // Evicting is reversible, but reaching outside the declared root is the
        // same bug whichever action follows it.
        #expect(receipt.wasAbandoned)
        #expect(evicted.recorded.isEmpty)
    }

    @Test("An eviction that fails is reported with what the system said")
    func failedEvictionIsReported() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("Documents/report.pages")

        struct Offline: LocalizedError {
            var errorDescription: String? { "The item is not in iCloud" }
        }

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            evict: { _ in throw Offline() }
        ).execute([.fixture(paths: [file], grade: .checkFirst, action: .evictCloudCopy)])

        #expect(receipt.trashedCount == 0)
        #expect(receipt.problems.first == .failed(path: file.path, message: "The item is not in iCloud"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The one test that uses the real Trash, because `trashItem` is the whole
    /// promise: a wrong answer costs a drag back out of the Trash, not the file.
    @Test("The real move is recoverable, not a delete")
    func realRemovalIsRecoverable() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("attic-test-recoverable.bin")

        let receipt = RemovalExecutor(definitions: [.fixture(root: tree.root)])
            .execute([.fixture(paths: [file], allocatedSize: DiskMeasure.measure(file).allocatedSize)])

        let outcome = try #require(receipt.outcomes.first)
        guard case .trashed(_, _, let inTrash) = outcome else {
            Issue.record("expected the file to be trashed, got \(outcome)")
            return
        }

        #expect(FileManager.default.fileExists(atPath: file.path) == false)

        // It is in the Trash, intact, and this test puts it back out again.
        let recovered = try #require(inTrash)
        #expect(FileManager.default.fileExists(atPath: recovered.path))
        try FileManager.default.removeItem(at: recovered)
    }
}
