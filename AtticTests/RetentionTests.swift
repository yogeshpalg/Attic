import Testing
import Foundation
@testable import Attic

/// Invariant 5. Whatever a rule declines to offer is *reported*, never silently
/// dropped. The failure this defends against is the one described in
/// `Finding.swift`: a retention bug and a genuinely empty folder look identical
/// from the outside, so "found nothing" would quietly come to mean "hid 1.15 GB
/// every single time".
@Suite("Retention and withholding")
struct RetentionTests {

    /// Backdates a directory and everything in it. Both are needed: `DiskMeasure`
    /// takes a directory's newest modification as the max of its own timestamp and
    /// every child's, and writing a file bumps the parent.
    @discardableResult
    private func age(_ tree: FixtureTree, _ relative: String, daysAgo: Double) throws -> URL {
        let directory = try tree.directory(relative)
        let file = try tree.file("\(relative)/build.o")
        try tree.setModified(file, daysAgo: daysAgo)
        try tree.setModified(directory, daysAgo: daysAgo)
        return directory
    }

    @Test("Recently used matches are withheld and the stale ones are offered")
    func recentlyTouchedIsWithheld() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try age(tree, "StaleProject", daysAgo: 30)
        try age(tree, "LiveProject", daysAgo: 2)

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                grouping: .perMatch,
                retention: .excludeModifiedWithin(days: 7)
            )
        ])

        #expect(result.findings.map(\.displayName) == ["StaleProject"])
        #expect(result.withheld.count == 1)
        #expect(result.withheld.first?.count == 1)
        #expect(result.withheld.first?.bytes ?? 0 > 0)
        #expect(result.withheld.first?.reason == .touchedRecently(days: 7))
    }

    @Test("Withholding everything still reports, and is not mistaken for an empty folder")
    func withholdingEverythingIsStillReported() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try age(tree, "LiveProjectA", daysAgo: 1)
        try age(tree, "LiveProjectB", daysAgo: 3)

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                grouping: .perMatch,
                retention: .excludeModifiedWithin(days: 7)
            )
        ])

        #expect(result.findings.isEmpty)
        #expect(result.withheld.first?.count == 2)
        #expect(result.withheld.first?.reason == .touchedRecently(days: 7))
        // Crucially not `.emptyRoot`: the folder had matches, they were withheld.
        #expect(result.unavailable.isEmpty)
    }

    @Test("The newest build per device is kept and the superseded ones are offered")
    func newestPerDeviceIsKept() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        // Device support folders are named `<device> <os> (<build>)`, so the text
        // before the first space is the device and everything after it varies per
        // OS release.
        try age(tree, "iPhone17,2 27.0 (24A437)", daysAgo: 10)
        try age(tree, "iPhone17,2 26.4 (23C1)", daysAgo: 200)
        try age(tree, "iPad14,1 27.0 (24A437)", daysAgo: 50)

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                grouping: .perMatch,
                retention: .keepNewestPerLeadingComponent
            )
        ])

        // Only the superseded iOS version for the phone is offered. The iPad has
        // one build, so it is the newest for its device and is kept.
        #expect(result.findings.map(\.displayName) == ["iPhone17,2 26.4 (23C1)"])
        #expect(result.withheld.count == 1)
        #expect(result.withheld.first?.count == 2)
        #expect(result.withheld.first?.reason == .newestForItsDevice)
    }

    @Test("Grouping is by device, not by OS version")
    func groupingIsByLeadingComponentOnly() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        // Grouping any later than the first space would put these two into
        // separate groups and offer neither.
        try age(tree, "iPhone17,2 27.0 (24A437)", daysAgo: 10)
        try age(tree, "iPhone17,2 26.4 (23C1)", daysAgo: 200)

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                grouping: .perMatch,
                retention: .keepNewestPerLeadingComponent
            )
        ])

        #expect(result.findings.count == 1)
        #expect(result.withheld.first?.count == 1)
    }

    @Test("A rule with no retention withholds nothing")
    func noRetentionWithholdsNothing() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try age(tree, "ProjectA", daysAgo: 1)
        try age(tree, "ProjectB", daysAgo: 400)

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch, retention: .none)
        ])

        #expect(result.findings.count == 2)
        #expect(result.withheld.isEmpty)
    }

    @Test("Withheld bytes account for every match left alone")
    func withheldBytesAreSummed() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try age(tree, "LiveProjectA", daysAgo: 1)
        try age(tree, "LiveProjectB", daysAgo: 1)

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                grouping: .perMatch,
                retention: .excludeModifiedWithin(days: 7)
            )
        ])

        // Two 4 KiB files, block-rounded, so only the floor is assertable.
        #expect(result.withheld.first?.bytes ?? 0 >= 8192)
    }
}
