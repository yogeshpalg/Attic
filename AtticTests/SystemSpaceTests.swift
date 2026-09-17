import Testing
import Foundation
@testable import Untitled_Project

/// Invariant 14. Space macOS manages is reported inside Attic rather than left to
/// System Settings — a cleaner that can see 68 GB and says nothing about it is
/// asking the user to finish the job in a second app.
///
/// It is reported *separately*, and that separation is the invariant. The system
/// gives one purgeable figure for the lot, and snapshots share storage with the
/// live volume and with each other, so no single snapshot has a size that could
/// honestly be listed beside it.
@Suite("Snapshot names")
struct SnapshotNameTests {

    private let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")

    @Test("An hourly snapshot is recognised and dated from its name")
    func timeMachineSnapshotIsDated() throws {
        let snapshot = LocalSnapshot(
            name: "com.apple.TimeMachine.2026-09-14-200806.local", volume: dataVolume
        )

        #expect(snapshot.kind == .timeMachine)

        let created = try #require(snapshot.createdAt)
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: created
        )
        // Named in the machine's own time zone, so it reads back as local time.
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 14)
        #expect(parts.hour == 20)
        #expect(parts.minute == 8)
        #expect(parts.second == 6)
    }

    @Test("A system update snapshot is recognised and never dated")
    func systemUpdateSnapshotIsSeparate() {
        let snapshot = LocalSnapshot(
            name: "com.apple.os.update-5203530F8BB20B9DABC5CE76A0FFE87C", volume: dataVolume
        )

        // Rolling back a system update is not disk space to reclaim.
        #expect(snapshot.kind == .systemUpdate)
        #expect(snapshot.createdAt == nil)
    }

    @Test("An unrecognised name is still listed rather than dropped")
    func unknownSnapshotIsStillListed() {
        let snapshot = LocalSnapshot(name: "some.other.snapshot", volume: dataVolume)

        #expect(snapshot.kind == .other)
        #expect(snapshot.createdAt == nil)
        #expect(snapshot.name == "some.other.snapshot")
    }

    @Test("A malformed date leaves the snapshot dateless, not misdated")
    func malformedDateIsNotGuessed() {
        #expect(LocalSnapshot.date(from: "com.apple.TimeMachine.not-a-date.local") == nil)
        #expect(LocalSnapshot.date(from: "com.apple.TimeMachine..local") == nil)
        #expect(LocalSnapshot.date(from: "") == nil)
    }

    @Test("Snapshots on different volumes are distinct items")
    func identityIncludesTheVolume() {
        let name = "com.apple.TimeMachine.2026-09-14-200806.local"
        let onData = LocalSnapshot(name: name, volume: dataVolume)
        let onSystem = LocalSnapshot(name: name, volume: URL(fileURLWithPath: "/"))

        #expect(onData.id != onSystem.id)
    }
}

/// The listing goes through `fs_snapshot_list` rather than a subprocess, and needs
/// no elevated privileges. These run against the real volume, so they assert
/// shape rather than a specific number of snapshots.
@Suite("Snapshot listing")
struct SnapshotStoreTests {

    @Test("Listing the data volume needs no privileges and returns usable names")
    func listingDataVolumeWorksUnprivileged() {
        let snapshots = SnapshotStore.list()

        for snapshot in snapshots {
            #expect(snapshot.name.isEmpty == false)
            #expect(snapshot.volume == SnapshotStore.dataVolume)
            // Every name the kernel hands back should be one we classify.
            #expect(snapshot.kind == .timeMachine || snapshot.kind == .systemUpdate
                    || snapshot.kind == .other)
        }

        // Each snapshot appears once: the parser walks entry lengths rather than
        // assuming a fixed stride, so a miscount would show up as duplicates.
        #expect(Set(snapshots.map(\.name)).count == snapshots.count)
    }

    @Test("A volume with no snapshots reports none rather than failing")
    func volumeWithoutSnapshotsIsEmpty() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        // A plain directory is not a volume root, so the call cannot succeed.
        #expect(SnapshotStore.list(on: tree.root).isEmpty)
        #expect(SnapshotStore.list(on: tree.root.appending(path: "never-created")).isEmpty)
    }
}

@Suite("System space report")
struct SystemSpaceReportTests {

    private func snapshot(_ stamp: String) -> LocalSnapshot {
        LocalSnapshot(
            name: "com.apple.TimeMachine.\(stamp).local",
            volume: SnapshotStore.dataVolume
        )
    }

    @Test("Only hourly snapshots are counted as reclaimable")
    func systemUpdateSnapshotsAreExcluded() {
        let report = SystemSpaceReport(
            purgeable: 68_000_000_000,
            snapshots: [
                snapshot("2026-09-14-200806"),
                snapshot("2026-09-15-183654"),
                LocalSnapshot(name: "com.apple.os.update-ABC", volume: SnapshotStore.dataVolume),
            ]
        )

        #expect(report.snapshots.count == 3)
        #expect(report.timeMachineSnapshots.count == 2)
    }

    @Test("An update's rollback point is reported, separately from the hourly ones")
    func updateSnapshotsAreReportedSeparately() {
        let report = SystemSpaceReport(
            purgeable: 0,
            snapshots: [
                snapshot("2026-09-14-200806"),
                LocalSnapshot(name: "com.apple.os.update-ABC123", volume: SnapshotStore.dataVolume),
            ]
        )

        // Two different promises: an hourly snapshot costs you a file you could
        // recover today, an update snapshot costs you the way back from a bad
        // macOS update. They are never counted as the same thing.
        #expect(report.timeMachineSnapshots.count == 1)
        #expect(report.systemUpdateSnapshots.map(\.name) == ["com.apple.os.update-ABC123"])
        #expect(report.isWorthShowing)
    }

    @Test("A Mac with only an update snapshot still has something to show")
    func updateSnapshotAloneIsWorthShowing() {
        let report = SystemSpaceReport(
            purgeable: 0,
            snapshots: [LocalSnapshot(name: "com.apple.os.update-ABC", volume: SnapshotStore.dataVolume)]
        )

        // Otherwise an old update holds gigabytes with nothing on screen to
        // explain where they went.
        #expect(report.isWorthShowing)
        #expect(report.timeMachineSnapshots.isEmpty)
    }

    @Test("The command shown for an update snapshot names that snapshot")
    func updateSnapshotCommandNamesIt() {
        let report = SystemSpaceReport(
            purgeable: 0,
            snapshots: [LocalSnapshot(name: "com.apple.os.update-ABC123", volume: SnapshotStore.dataVolume)]
        )

        // Shown, never run: it needs root, and it is the only way back.
        #expect(report.discardUpdateSnapshotCommand.contains("tmutil deletelocalsnapshots"))
        #expect(report.discardUpdateSnapshotCommand.contains("com.apple.os.update-ABC123"))
        #expect(report.discardUpdateSnapshotCommand.hasPrefix("sudo "))
    }

    @Test("Rolling back an update is explained in the same three sentences")
    func updateSnapshotExplainsItself() {
        let report = SystemSpaceReport(purgeable: 0, snapshots: [])

        #expect(report.updateSnapshotExplanation.whatThisIs.isEmpty == false)
        #expect(report.updateSnapshotExplanation.whatStopsWorking.contains("undo"))
        // The reassurance someone needs before touching anything called a snapshot.
        #expect(report.updateSnapshotExplanation.whatStopsWorking.contains("files are not"))
    }

    @Test("The oldest and newest snapshots frame what would be lost")
    func datesBoundTheRange() throws {
        let report = SystemSpaceReport(
            purgeable: 1,
            snapshots: [
                snapshot("2026-09-15-183654"),
                snapshot("2026-09-14-200806"),
                snapshot("2026-09-14-230726"),
            ]
        )

        let oldest = try #require(report.oldestSnapshot)
        let newest = try #require(report.newestSnapshot)

        #expect(oldest < newest)
        #expect(Calendar.current.component(.day, from: oldest) == 14)
        #expect(Calendar.current.component(.day, from: newest) == 15)
    }

    @Test("Nothing is shown when there is nothing to report")
    func emptyReportIsNotWorthShowing() {
        #expect(SystemSpaceReport(purgeable: 0, snapshots: []).isWorthShowing == false)

        // Purgeable space with no snapshots is still worth saying — it is made up
        // of other things macOS will free, such as evictable iCloud copies.
        #expect(SystemSpaceReport(purgeable: 1_000, snapshots: []).isWorthShowing)
        #expect(
            SystemSpaceReport(purgeable: 0, snapshots: [snapshot("2026-09-14-200806")])
                .isWorthShowing
        )
    }

    @Test("The command shown is the one that would reclaim the reported bytes")
    func reclaimCommandNamesTheVolumeAndAmount() {
        let report = SystemSpaceReport(purgeable: 68_000_000_000, snapshots: [])

        // Shown, never run. It names an amount and an urgency because that is
        // what macOS itself does behind the button in Storage Settings.
        #expect(report.reclaimCommand.contains("tmutil thinlocalsnapshots"))
        #expect(report.reclaimCommand.contains("/System/Volumes/Data"))
        #expect(report.reclaimCommand.contains("68000000000"))
    }

    @Test("The report explains itself in the same three sentences as a finding")
    func reportExplainsItself() {
        let report = SystemSpaceReport(purgeable: 1, snapshots: [])

        #expect(report.explanation.whatThisIs.isEmpty == false)
        #expect(report.explanation.whatStopsWorking.isEmpty == false)
        #expect(report.explanation.doesItComeBack.isEmpty == false)
        // The promise that external backups are safe is the one a user needs
        // before touching anything with "Time Machine" in the name.
        #expect(report.explanation.whatStopsWorking.contains("external"))
    }

    @Test("Reading the real machine produces a coherent report")
    func liveReportIsCoherent() {
        let report = SystemSpaceReport.read()

        #expect(report.purgeable >= 0)
        #expect(report.snapshots.count >= report.timeMachineSnapshots.count)
    }
}

/// The separation is the point: these bytes are reported, and they never join the
/// figure the scan arrived at.
@Suite("System space accounting")
@MainActor
struct SystemSpaceAccountingTests {

    @Test("Snapshot space is reported without inflating what the scan found")
    func systemSpaceStaysOutOfTheScanTotal() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")

        let model = ScanModel(
            store: DefinitionStore(source: SingleSource(rule: .fixture(root: tree.root)))
        )
        model.sizeFloor = .everything
        model.startScan()
        for _ in 0..<600 {
            if model.phase == .review { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let system = try #require(model.systemSpace)
        let found = model.totalFound

        // The scan found one small fixture directory. Whatever macOS is holding,
        // the scan's total is unchanged by it.
        #expect(found > 0)
        #expect(found < 1_000_000)
        #expect(system.purgeable >= 0)
        #expect(model.totalFound == found)
    }
}

private struct SingleSource: DefinitionSource {
    let rule: RuleDefinition

    func load() throws -> [RuleDefinition] { [rule] }
}
