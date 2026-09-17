import Testing
import Foundation
@testable import Attic

/// Invariant 2. These are the tests that must fail the build rather than merely
/// log at runtime: if a scanner can emit a path outside its declared root, every
/// other safety measure in the app is decoration.
@Suite("Path containment")
struct ContainmentTests {

    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test("A sibling sharing a string prefix is not contained")
    func siblingSharingPrefixIsNotContained() {
        // The failure this guards: `hasPrefix` would report Dev as inside Developer.
        let developer = home.appending(path: "Library/Developer")
        let dev = home.appending(path: "Library/Dev")

        #expect(PathContainment.contains(root: developer, candidate: dev) == false)
        #expect(PathContainment.contains(root: dev, candidate: developer) == false)
    }

    @Test("A root contains itself")
    func rootContainsItself() {
        let root = home.appending(path: "Library/Developer/Xcode/DerivedData")
        #expect(PathContainment.contains(root: root, candidate: root))
    }

    @Test("A child is contained, a parent is not")
    func childIsContainedParentIsNot() {
        let root = home.appending(path: "Library/Developer/Xcode")
        #expect(PathContainment.contains(root: root, candidate: root.appending(path: "DerivedData/x")))
        #expect(PathContainment.contains(root: root, candidate: home.appending(path: "Library")) == false)
    }

    @Test("A symlink pointing out of the root is not contained")
    func symlinkEscapingRootIsNotContained() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }

        let scanned = try tree.directory("scanned")
        let elsewhere = try tree.directory("elsewhere")
        let escape = try tree.symlink("scanned/escape", to: elsewhere)

        #expect(PathContainment.contains(root: scanned, candidate: escape) == false)
    }

    @Test("Firmlinked and symlinked system paths normalise before comparison")
    func systemPathsNormalise() {
        // /var is a symlink to /private/var. A rule rooted at one form must still
        // recognise a candidate expressed in the other.
        let varRoot = URL(fileURLWithPath: "/var/folders")
        let privateChild = URL(fileURLWithPath: "/private/var/folders/xx/yy")

        #expect(PathContainment.contains(root: varRoot, candidate: privateChild))
        #expect(PathContainment.canonical(URL(fileURLWithPath: "/tmp")).path == "/private/tmp")
    }

    @Test("Trailing slashes and dot components do not change containment")
    func normalisationIsStable() {
        let root = URL(fileURLWithPath: "/private/tmp/a")
        let messy = URL(fileURLWithPath: "/private/tmp/a/./b/../b/c")
        #expect(PathContainment.contains(root: root, candidate: messy))
    }

    @Test("Overlap is symmetric")
    func overlapIsSymmetric() {
        let parent = URL(fileURLWithPath: "/private/tmp/a")
        let child = URL(fileURLWithPath: "/private/tmp/a/b")

        #expect(PathContainment.overlaps(parent, child))
        #expect(PathContainment.overlaps(child, parent))
        #expect(PathContainment.overlaps(parent, URL(fileURLWithPath: "/private/tmp/z")) == false)
    }
}

/// Invariant 3. The denylist is compiled in, and no definition — including one
/// fetched from the definitions repository — can extend or override it.
@Suite("Compiled denylist")
struct DenylistTests {

    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test("Unrecoverable Xcode data is refused")
    func unrecoverableDataRefused() {
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode/Archives")) == false)
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode/UserData/KeyBindings")) == false)
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode/UserData/Provisioning Profiles")) == false)
        #expect(Denylist.permits(home.appending(path: "Documents/tax")) == false)
        #expect(Denylist.permits(home.appending(path: "Library/Application Support/MobileSync/Backup/abc")) == false)
    }

    @Test("Reclaimable siblings inside UserData are still permitted")
    func reclaimableUserDataPermitted() {
        // The spec denylisted all of UserData, which would have made the Previews,
        // IB Support and assistant-snapshot rules unreachable. The protection
        // belongs on the unrecoverable leaves, not the shared parent.
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode/UserData/Previews")))
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode/UserData/IB Support")))
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode/UserData/CodingAssistant")))
    }

    @Test("A path that merely contains a protected path is refused")
    func parentOfProtectedPathRefused() {
        // Selecting this would sweep Archives away with it.
        #expect(Denylist.permits(home.appending(path: "Library/Developer/Xcode")) == false)
        #expect(Denylist.permits(home.appending(path: "Library/Developer")) == false)
        #expect(Denylist.permits(URL(fileURLWithPath: "/")) == false)
    }

    @Test("Assistant memory directories are refused, transcripts are not")
    func assistantMemoryRefused() {
        let assistant = home.appending(path: "Library/Developer/Xcode/CodingAssistant")
        #expect(Denylist.permits(assistant.appending(path: "ClaudeAgentConfig/projects/p/memory/note.md")) == false)
        #expect(Denylist.permits(assistant.appending(path: "ClaudeAgentConfig/projects/p/memory")) == false)
        #expect(Denylist.permits(assistant.appending(path: "ClaudeAgentConfig/projects/p/session.jsonl")))
    }

    @Test("No shipped rule looks inside a denylisted path")
    func noShippedRuleScansADeniedRoot() {
        for rule in Catalogue.all {
            #expect(
                Denylist.scanRejection(for: rule.root.url) == nil,
                "rule \(rule.id) is rooted inside a denylisted path"
            )
        }
    }

    @Test("No shipped rule offers a denylisted path as the thing it removes")
    func noShippedWholeRootRuleTargetsADeniedPath() {
        // A `wholeRoot` rule's root is the item it offers, so for those the
        // stricter check applies: it must clear the denylist in both directions.
        for rule in Catalogue.all where rule.match == .wholeRoot {
            #expect(
                Denylist.permits(rule.root.url),
                "rule \(rule.id) offers a denylisted path"
            )
        }
    }

    @Test("Scanning above a protected path is allowed; removing it is not")
    func scanningAboveAProtectedPathIsAllowed() {
        let library = home.appending(path: "Library")

        // ~/Library holds the device backups, so it can never be removed — but a
        // rule has to be able to look through it to find anything at all.
        #expect(Denylist.scanRejection(for: library) == nil)
        #expect(Denylist.permits(library) == false)

        // Rooted *inside* a protected path stays refused, and nothing is read.
        #expect(Denylist.scanRejection(for: home.appending(path: "Documents")) != nil)
        #expect(
            Denylist.scanRejection(
                for: home.appending(path: "Library/Application Support/MobileSync/Backup/abc")
            ) != nil
        )
    }
}
