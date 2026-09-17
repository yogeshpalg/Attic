import Testing
import Foundation
@testable import Attic

/// Invariant 6. The number on screen is the number the user will check against
/// `du`, so the walk has to agree with the filesystem — and where it cannot read
/// part of a tree it has to say so rather than quietly reporting a smaller total.
///
/// Sizes are asserted as floors throughout: `totalFileAllocatedSize` is
/// block-rounded, so a 4 KiB file legitimately reports more than 4096 bytes.
@Suite("Disk measurement")
struct DiskMeasureTests {

    @Test("A single file measures as one file with its allocated size")
    func singleFileReading() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("one.bin", bytes: 4096)

        let reading = DiskMeasure.measure(file)

        #expect(reading.fileCount == 1)
        #expect(reading.allocatedSize >= 4096)
        #expect(reading.newestModification != nil)
        #expect(reading.encounteredDenial == false)
    }

    @Test("A directory counts regular files only, not the directories holding them")
    func directoryCountsFilesOnly() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("tree/one.bin", bytes: 4096)
        try tree.file("tree/nested/two.bin", bytes: 4096)
        try tree.directory("tree/empty")

        let reading = DiskMeasure.measure(tree.root.appending(path: "tree"))

        // Two files across three directories.
        #expect(reading.fileCount == 2)
        #expect(reading.allocatedSize >= 8192)
    }

    @Test("A directory reports its newest child's modification date")
    func directoryTakesNewestChildDate() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let directory = try tree.directory("tree")
        let recent = try tree.file("tree/recent.bin")
        let old = try tree.file("tree/old.bin")
        try tree.setModified(recent, daysAgo: 10)
        try tree.setModified(old, daysAgo: 50)
        // Backdated last: writing the files bumps the directory itself.
        try tree.setModified(directory, daysAgo: 100)

        let newest = try #require(DiskMeasure.measure(directory).newestModification)

        #expect(newest > Date(timeIntervalSinceNow: -11 * 86_400))
        #expect(newest < Date(timeIntervalSinceNow: -9 * 86_400))
    }

    @Test("A path that does not exist measures as zero bytes")
    func missingPathMeasuresZero() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let reading = DiskMeasure.measure(tree.root.appending(path: "never-created"))

        #expect(reading.allocatedSize == 0)
        #expect(reading.newestModification == nil)
        // Pinning a quirk: an unreadable path falls into the non-directory branch
        // and is counted as one file. It cannot leak into the UI, because both
        // finding constructors require `allocatedSize > 0` — but a caller reading
        // `fileCount` alone would be misled.
        #expect(reading.fileCount == 1)
    }

    @Test("An unreadable directory is reported as denied, not as empty")
    func unreadableDirectoryReportsDenial() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let locked = try tree.directory("locked")
        try tree.file("locked/secret.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
        }

        let reading = DiskMeasure.measure(locked)

        // This is how a permission problem reaches the interface instead of
        // silently understating the total.
        #expect(reading.encounteredDenial)
    }
}

/// `SizeReading.+` is the seed and the accumulator for every `.single` grouping
/// finding (`RuleScanner.makeSingleFinding`), so identity and summing both matter.
@Suite("Size reading arithmetic")
struct SizeReadingTests {

    @Test("An empty reading is the identity")
    func emptyReadingIsIdentity() {
        let reading = SizeReading(
            allocatedSize: 4096, fileCount: 1, newestModification: Date(timeIntervalSince1970: 1000)
        )

        #expect(SizeReading() + reading == reading)
        #expect(reading + SizeReading() == reading)
    }

    @Test("Adding sums sizes and counts and takes the later date")
    func additionSumsAndTakesLatest() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 9000)
        let sum = SizeReading(allocatedSize: 4096, fileCount: 1, newestModification: earlier)
            + SizeReading(allocatedSize: 8192, fileCount: 3, newestModification: later)

        #expect(sum.allocatedSize == 12_288)
        #expect(sum.fileCount == 4)
        #expect(sum.newestModification == later)
    }

    @Test("A date survives being added to a reading that has none")
    func additionKeepsTheOnlyDate() {
        let date = Date(timeIntervalSince1970: 1000)
        let sum = SizeReading(allocatedSize: 1, fileCount: 1, newestModification: nil)
            + SizeReading(allocatedSize: 1, fileCount: 1, newestModification: date)

        #expect(sum.newestModification == date)
    }

    @Test("A denial anywhere in the sum is carried")
    func denialIsCarried() {
        let clean = SizeReading(allocatedSize: 1, fileCount: 1)
        let denied = SizeReading(allocatedSize: 1, fileCount: 1, encounteredDenial: true)

        #expect((clean + denied).encounteredDenial)
        #expect((denied + clean).encounteredDenial)
        #expect((clean + clean).encounteredDenial == false)
    }
}

/// The gap between `available` and `availableForImportantUsage` is most of the
/// reason a cleanup can look like it did nothing, so both are read and reported.
@Suite("Volume space")
struct VolumeSpaceTests {

    @Test("The data volume reports a coherent reading")
    func dataVolumeReadingIsCoherent() throws {
        let reading = try #require(VolumeSpace.read())

        #expect(reading.total > 0)
        #expect(reading.available >= 0)
        #expect(reading.available <= reading.total)
        #expect(reading.purgeable >= 0)
    }

    @Test("A volume that cannot be read reports nothing rather than zero")
    func unreadableVolumeReturnsNil() {
        #expect(VolumeSpace.read(URL(fileURLWithPath: "/nonexistent-volume")) == nil)
    }
}
