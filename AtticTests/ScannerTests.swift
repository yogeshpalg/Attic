import Testing
import Foundation
@testable import Attic

/// Invariant 1. A rule may only ever emit paths that its own declaration reaches:
/// inside the declared root, past the compiled denylist, and not excluded. These
/// suites drive the real engine over a throwaway tree rather than unit-testing the
/// gates in isolation, because the gates being individually correct is not the same
/// claim as the scanner actually applying them.
@Suite("Rule matching")
struct MatchingTests {

    @Test("A wholeRoot rule offers the root as one item")
    func wholeRootMatchesTheRootItself() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("build/one.o")
        try tree.file("build/two.o")

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .wholeRoot, grouping: .single)
        ])

        #expect(result.findings.count == 1)
        // Compared as paths, not URLs: the rule's root goes through
        // `URL(fileURLWithPath:)`, which marks it as a directory, so the two URLs
        // differ by a trailing slash while naming the same place.
        #expect(result.findings.first?.paths.map(\.path) == [tree.root.path])
        #expect(result.findings.first?.fileCount == 2)
        #expect(result.rejected.isEmpty)
    }

    @Test("An immediateChildren rule offers each subdirectory and ignores loose files")
    func immediateChildrenMatchesDirectoriesOnly() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        try tree.file("ProjectB/build.o")
        try tree.file("loose.txt")

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch)
        ])

        #expect(result.findings.count == 2)
        #expect(Set(result.findings.map(\.displayName)) == ["ProjectA", "ProjectB"])
        #expect(Set(result.findings.map(\.id)) == ["test.rule.ProjectA", "test.rule.ProjectB"])
    }

    @Test("A namedChildren rule offers only the names it lists")
    func namedChildrenMatchesByExactName() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ModuleCache.noindex/a.pcm")
        try tree.file("SymbolCache.noindex/b.db")
        try tree.file("ProjectA/build.o")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .namedChildren(["ModuleCache.noindex", "SymbolCache.noindex"]),
                grouping: .single
            )
        ])

        let paths = Set((result.findings.first?.paths ?? []).map(\.lastPathComponent))
        #expect(result.findings.count == 1)
        #expect(paths == ["ModuleCache.noindex", "SymbolCache.noindex"])
    }

    @Test("A prefix rule matches the releases it has not heard of yet")
    func childrenWithPrefixMatchesFutureNames() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Install macOS Tahoe.app/Contents/installer.dmg")
        // The point of the prefix: this release did not exist when the rule was
        // written, and an exact list would quietly stop finding 15 GB.
        try tree.file("Install macOS Whatever Comes Next.app/Contents/installer.dmg")
        try tree.file("Install OS X El Capitan.app/Contents/installer.dmg")
        try tree.file("Safari.app/Contents/binary")
        try tree.file("Installer Helper.app/Contents/binary")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .childrenWithPrefix(["Install macOS", "Install OS X"]),
                grouping: .perMatch
            )
        ])

        #expect(
            Set(result.findings.map(\.displayName)) == [
                "Install macOS Tahoe.app",
                "Install macOS Whatever Comes Next.app",
                "Install OS X El Capitan.app",
            ]
        )
    }

    @Test("A prefix is a prefix, not a substring")
    func prefixDoesNotMatchMidName() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        // Would match if the rule searched anywhere in the name.
        try tree.file("My Install macOS Notes.app/Contents/binary")
        try tree.file("Install macOS Tahoe.app/Contents/binary")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .childrenWithPrefix(["Install macOS"]),
                grouping: .perMatch
            )
        ])

        #expect(result.findings.map(\.displayName) == ["Install macOS Tahoe.app"])
    }

    @Test("A filesWithExtension rule recurses and matches case-insensitively")
    func filesWithExtensionRecurses() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("projects/one/session.jsonl")
        try tree.file("projects/two/deep/nested/session.JSONL")
        try tree.file("projects/one/notes.txt")

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .filesWithExtension("jsonl"), grouping: .single)
        ])

        let names = Set((result.findings.first?.paths ?? []).map(\.lastPathComponent))
        #expect(names == ["session.jsonl", "session.JSONL"])
        #expect(result.findings.first?.fileCount == 2)
    }

    @Test("Single grouping collapses every match into one finding")
    func singleGroupingSumsMatches() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o", bytes: 8192)
        try tree.file("ProjectB/build.o", bytes: 8192)

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .immediateChildren, grouping: .single)
        ])

        let finding = try #require(result.findings.first)
        #expect(result.findings.count == 1)
        #expect(finding.paths.count == 2)
        #expect(finding.fileCount == 2)
        // Allocated size is block-rounded, so only the floor is assertable.
        #expect(finding.allocatedSize >= 16_384)
    }

    @Test("The DerivedData hash is dropped from the display name")
    func derivedDataHashIsDropped() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("MyProject-abcdefghijklmnopqrst/build.o")
        try tree.file("MyProject-short/build.o")

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .immediateChildren, grouping: .perMatch)
        ])

        // A short trailing component is part of the project's name, not a hash.
        #expect(Set(result.findings.map(\.displayName)) == ["MyProject", "MyProject-short"])
    }

    @Test("Name shortening applies only where folder names carry a hash")
    func hashStrippingIsScopedToImmediateChildren() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("MyProject-abcdefghijklmnopqrst/build.o")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .namedChildren(["MyProject-abcdefghijklmnopqrst"]),
                grouping: .perMatch
            )
        ])

        #expect(result.findings.first?.displayName == "MyProject-abcdefghijklmnopqrst")
    }
}

/// Invariant 1, continued. Exclusions are evaluated against the portion of the path
/// *below* the root. A rule whose exclusion accidentally matched a component of the
/// user's home directory path would silently exclude everything it was meant to find.
@Suite("Rule exclusions")
struct ExclusionTests {

    @Test("A name suffix exclusion withholds the matching children")
    func nameSuffixExclusion() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        try tree.file("ModuleCache.noindex/a.pcm")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                exclude: [.nameSuffix(".noindex")],
                grouping: .perMatch
            )
        ])

        #expect(result.findings.map(\.displayName) == ["ProjectA"])
    }

    @Test("A file extension exclusion withholds by extension")
    func fileExtensionExclusion() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ProjectA/build.o")
        try tree.file("Legacy.bundle/contents.bin")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                exclude: [.fileExtension("bundle")],
                grouping: .perMatch
            )
        ])

        #expect(result.findings.map(\.displayName) == ["ProjectA"])
    }

    @Test("A path component exclusion is relative to the root")
    func pathComponentExclusion() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("cache/transcript.jsonl")
        try tree.file("keep/transcript.jsonl")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .filesWithExtension("jsonl"),
                exclude: [.pathComponent("cache")],
                grouping: .single
            )
        ])

        let paths = try #require(result.findings.first?.paths)
        #expect(paths.count == 1)
        #expect(paths.first?.pathComponents.contains("keep") == true)
    }

    @Test("Names owned by the identifier rules are left for them")
    func bundleIdentifierNamesAreExcluded() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("Microsoft Edge/cache.bin")
        try tree.file("pip/wheel.bin")
        try tree.file("com.operasoftware.Opera/cache.bin")
        try tree.file("org.swift.swiftpm/repos.bin")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                exclude: [.bundleIdentifierNames],
                grouping: .perMatch
            )
        ])

        // A folder sweep and an orphan rule both looking at ~/Library/Caches
        // would otherwise claim the same bytes, and the total would count them
        // twice. The identifier-shaped names belong to the orphan rules.
        #expect(Set(result.findings.map(\.displayName)) == ["Microsoft Edge", "pip"])
    }

    @Test("A preference file named after an identifier is excluded too")
    func bundleIdentifierPlistsAreExcluded() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("com.example.app.plist")
        try tree.file("settings.plist")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .filesWithExtension("plist"),
                exclude: [.bundleIdentifierNames],
                grouping: .single
            )
        ])

        let names = (result.findings.first?.paths ?? []).map(\.lastPathComponent)
        #expect(names == ["settings.plist"])
    }

    @Test("A component name from above the root excludes nothing")
    func componentsAboveTheRootAreIgnored() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("keep/transcript.jsonl")

        // The fixture lives under /private/var/folders/…, so "folders" is a real
        // component of every candidate's absolute path. Evaluating exclusions
        // against the absolute path would drop every match here.
        #expect(tree.root.pathComponents.contains("folders"))

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .filesWithExtension("jsonl"),
                exclude: [.pathComponent("folders")],
                grouping: .single
            )
        ])

        #expect(result.findings.count == 1)
    }
}

/// Invariant 2, through the engine. `PathContainment` being correct in isolation is
/// a separate claim from the scanner refusing to emit what it rejects — and a
/// rejection is reported, never quietly dropped, because it means the rule is wrong.
@Suite("Scanner gates")
struct GateTests {

    @Test("A matched file resolving outside the root is rejected, not offered")
    func symlinkedFileEscapingRootIsRejected() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let scanned = try tree.directory("scanned")
        try tree.file("scanned/real.jsonl")
        let outside = try tree.file("elsewhere/secret.jsonl")
        try tree.symlink("scanned/link.jsonl", to: outside)

        let result = await ScanProbe.run([
            .fixture(root: scanned, match: .filesWithExtension("jsonl"), grouping: .single)
        ])

        let offered = (result.findings.first?.paths ?? []).map(\.lastPathComponent)
        #expect(offered == ["real.jsonl"])
        #expect(result.rejected.count == 1)
        #expect(result.rejected.first?.reason == .outsideDeclaredRoot)
        #expect(result.rejected.first?.path.hasSuffix("scanned/link.jsonl") == true)
    }

    @Test("A symlinked directory is never matched as a child")
    func symlinkedDirectoryIsNotMatched() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let scanned = try tree.directory("scanned")
        try tree.file("scanned/real/build.o")
        let elsewhere = try tree.directory("elsewhere")
        try tree.file("elsewhere/private.key")
        try tree.symlink("scanned/escape", to: elsewhere)

        let result = await ScanProbe.run([
            .fixture(root: scanned, match: .immediateChildren, grouping: .perMatch)
        ])

        // The escape cannot be emitted, which is what matters. Note how it is
        // stopped, though: `isDirectoryKey` is false for a symlink, so
        // `directories(in:)` filters it out before the containment gate ever sees
        // it — dropped rather than reported. Only the `filesWithExtension` path
        // above reaches the gate and produces a rejection.
        #expect(result.findings.map(\.displayName) == ["real"])
        #expect(result.rejected.isEmpty)
    }

    @Test("A rule rooted at a denylisted path produces nothing at all")
    func denylistedRootProducesNothing() async {
        // Nothing is created here and nothing is enumerated: the root gate fires
        // before the scanner reads the directory.
        let documents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")

        let result = await ScanProbe.run([
            .fixture(root: documents, match: .immediateChildren, grouping: .perMatch)
        ])

        #expect(result.findings.isEmpty)
        #expect(result.rejected.count == 1)
        #expect(result.rejected.first?.reason == .denylisted)
    }

    @Test("A missing root reports why rather than reporting nothing")
    func missingRootIsUnavailable() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let result = await ScanProbe.run([
            .fixture(root: tree.root.appending(path: "never-created"), match: .wholeRoot)
        ])

        #expect(result.findings.isEmpty)
        #expect(result.unavailable == [.rootMissing])
    }

    @Test("An empty root reports why rather than reporting nothing")
    func emptyRootIsUnavailable() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let empty = try tree.directory("empty")

        let result = await ScanProbe.run([
            .fixture(root: empty, match: .immediateChildren)
        ])

        #expect(result.findings.isEmpty)
        #expect(result.unavailable == [.emptyRoot])
    }

    @Test("A root whose every match is excluded says so, rather than 'empty'")
    func fullyExcludedRootIsNotCalledEmpty() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("ModuleCache.noindex/a.pcm")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                exclude: [.nameSuffix(".noindex")]
            )
        ])

        // The folder holds a file. Reporting "the folder this looks in is
        // empty" would send somebody looking for a problem that is not there.
        #expect(result.unavailable == [.everythingExcluded])
    }
}

/// Invariant 4. A rule the app cannot act on is still shown with its size and
/// explanation — it just offers no checkbox. Dropping it instead would understate
/// what is on disk, which is the one thing the headline figure must not do.
@Suite("Offered versus shown")
struct SelectabilityTests {

    @Test("A detect-only rule is found but not selectable")
    func detectOnlyIsFoundButNotSelectable() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("snapshot.plist")

        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .wholeRoot,
                grouping: .single,
                status: .detectOnly
            )
        ])

        let finding = try #require(result.findings.first)
        #expect(finding.allocatedSize > 0)
        #expect(finding.isSelectable == false)
    }

    @Test("A keep-graded rule is found but not selectable")
    func keepGradeIsFoundButNotSelectable() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("simulator/device.img")

        let result = await ScanProbe.run([
            .fixture(root: tree.root, match: .wholeRoot, grouping: .single, grade: .keep)
        ])

        let finding = try #require(result.findings.first)
        #expect(finding.allocatedSize > 0)
        #expect(finding.isSelectable == false)
    }
}
