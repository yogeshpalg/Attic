import Testing
import Foundation
@testable import Untitled_Project

/// Invariant 9. The catalogue is the unit that will eventually be fetched from the
/// public definitions repository rather than compiled in, so its integrity cannot
/// rest on review alone: a duplicate id silently merges two rules, and a rule from
/// a newer release reaching an older build has to be inert rather than wrong.
@Suite("Definition integrity")
struct CatalogueTests {

    @Test("Rule identifiers are unique")
    func ruleIdentifiersAreUnique() {
        let ids = Catalogue.all.map(\.id)

        // Ids prefix every `Finding.id`, so a collision merges two rules' items.
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every rule explains itself in three sentences")
    func everyRuleExplainsItself() {
        for rule in Catalogue.all {
            #expect(rule.explanation.whatThisIs.isEmpty == false, "\(rule.id) has no description")
            #expect(
                rule.explanation.whatStopsWorking.isEmpty == false,
                "\(rule.id) does not say what stops working"
            )
            #expect(
                rule.explanation.doesItComeBack.isEmpty == false,
                "\(rule.id) does not say whether it comes back"
            )
        }
    }

    @Test("No user-facing rule name contains a file path")
    func ruleNamesCarryNoPaths() {
        for rule in Catalogue.all {
            // Paths belong in the expanded explanation, never in the row title.
            #expect(rule.displayName.contains("/") == false, "\(rule.id) names a path")
            #expect(rule.displayName.isEmpty == false)
        }
    }

    @Test("Every rule Attic offers to empty is one it can act on as the user")
    func trashRulesNeedNoEscalation() {
        for rule in Catalogue.all where rule.action == .trash {
            // A trash action needing admin rights would degrade to Reveal at plan
            // time, so the rule would never do what its copy implies.
            #expect(rule.privilege == .user, "\(rule.id) would silently degrade to reveal")
        }
    }

    @Test("Every command a rule names is one of the compiled allowlist")
    func commandsComeFromTheAllowlist() {
        let permittedBinaries = ["xcrun", "tmutil", "brew", "go", "docker"]

        for rule in Catalogue.all {
            guard case .command(let command) = rule.action else { continue }
            let binary = command.displayForm.split(separator: " ").first.map(String.init)
            // No shell string originates from data: a definition can only name a
            // case of `KnownCommand`, and every case runs a known binary.
            #expect(permittedBinaries.contains(binary ?? ""), "\(rule.id) names \(command.displayForm)")
        }
    }

    @Test("No two rules can claim the same bytes")
    func rulesDoNotOverlap() {
        // The orphan rules match by identifier anywhere under ~/Library. Any
        // other rule that sweeps folders under the same tree has to leave
        // identifier-shaped names alone, or the same bytes are found twice and
        // the headline figure is wrong.
        let identifierRules = Catalogue.all.filter {
            if case .orphanedSupport = $0.match { return true } else { return false }
        }
        #expect(identifierRules.isEmpty == false)

        // Derived from the same list the orphan scanner walks, so adding a
        // location there cannot quietly leave an overlap behind here.
        let claimed = OrphanLocation
            .standard(home: FileManager.default.homeDirectoryForCurrentUser)
            .map { PathContainment.canonical($0.directory).path }

        for rule in Catalogue.all {
            if case .orphanedSupport = rule.match { continue }
            // Only a rule sweeping one of those exact folders can collide:
            // DerivedData children are named `Project-hash` and device support
            // children `iPhone17,2 27.0 (24A437)`, neither of which is an
            // identifier, so those rules have nothing to avoid.
            guard claimed.contains(PathContainment.canonical(rule.root.url).path) else { continue }

            #expect(
                rule.exclude.contains(.bundleIdentifierNames),
                "rule \(rule.id) sweeps a folder the identifier rules also claim"
            )
        }
    }

    @Test("No rule is rooted inside another rule that sweeps whole folders")
    func wholeRootRulesDoNotNest() {
        let wholeRootRules = Catalogue.all.filter { $0.match == .wholeRoot }

        for outer in wholeRootRules {
            for inner in wholeRootRules where inner.id != outer.id {
                #expect(
                    PathContainment.contains(root: outer.root.url, candidate: inner.root.url) == false,
                    "\(inner.id) sits inside \(outer.id), so both would offer the same bytes"
                )
            }
        }
    }

    @Test("The two DerivedData rules cannot both claim the same folder")
    func derivedDataRulesDoNotOverlap() async throws {
        let projects = try #require(Catalogue.all.first { $0.id == "xcode.derived-data.projects" })
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("MyProject-abcdefghijklmnopqrst/build.o")
        for cache in Catalogue.derivedDataSharedCaches {
            try tree.file("\(cache)/blob.bin")
        }

        // The shipped exclusions, applied to a DerivedData-shaped tree. Anything
        // the shared-cache rule matches has to be excluded here, or its bytes are
        // counted twice and offered twice.
        let result = await ScanProbe.run([
            .fixture(
                root: tree.root,
                match: .immediateChildren,
                exclude: projects.exclude,
                grouping: .perMatch
            )
        ])

        #expect(result.findings.map(\.displayName) == ["MyProject"])
    }
}

/// A source that stands in for the definitions repository.
private struct StubSource: DefinitionSource {
    var rules: [RuleDefinition] = []
    var failure: (any Error)?

    func load() throws -> [RuleDefinition] {
        if let failure { throw failure }
        return rules
    }
}

private struct StubFailure: Error {}

/// Invariant 10. Rules can ship ahead of the app that understands them, so the
/// store filters by version rather than trusting whatever arrives.
@Suite("Definition store")
struct DefinitionStoreTests {

    private func rule(_ id: String, minAppVersion: String) -> RuleDefinition {
        // The root is never scanned here: the store filters by version alone.
        .fixture(id: id, minAppVersion: minAppVersion, root: URL(fileURLWithPath: "/private/tmp"))
    }

    private func osBound(
        _ id: String, minOS: String? = nil, maxOS: String? = nil
    ) -> RuleDefinition {
        .fixture(
            id: id, minOSVersion: minOS, maxOSVersion: maxOS,
            root: URL(fileURLWithPath: "/private/tmp")
        )
    }

    @Test("A rule needing a newer app is filtered out")
    func newerRulesAreInert() {
        let store = DefinitionStore(
            source: StubSource(rules: [
                rule("current", minAppVersion: "1.0"),
                rule("future", minAppVersion: "2.0"),
            ]),
            appVersion: "1.0"
        )

        #expect(store.definitions().map(\.id) == ["current"])
    }

    @Test("Versions are compared numerically, not alphabetically")
    func versionsCompareNumerically() {
        // Alphabetically "1.9" sorts after "1.10", which would wrongly drop a rule
        // the app is new enough to run.
        let store = DefinitionStore(
            source: StubSource(rules: [
                rule("older", minAppVersion: "1.9"),
                rule("newer", minAppVersion: "1.11"),
            ]),
            appVersion: "1.10"
        )

        #expect(store.definitions().map(\.id) == ["older"])
    }

    @Test("A source that fails falls back to the compiled catalogue")
    func failingSourceFallsBack() {
        let store = DefinitionStore(
            source: StubSource(failure: StubFailure()),
            appVersion: "1.0"
        )

        #expect(store.definitions().map(\.id) == Catalogue.all.map(\.id))
    }

    @Test("A source with nothing in it yields nothing, rather than falling back")
    func emptySourceIsHonoured() {
        // An empty answer is a valid answer — only a failure falls back.
        let store = DefinitionStore(source: StubSource(rules: []), appVersion: "1.0")

        #expect(store.definitions().isEmpty)
    }

    @Test("A rule for a newer macOS is inert on an older one")
    func rulesForNewerSystemsAreInert() {
        let store = DefinitionStore(
            source: StubSource(rules: [
                osBound("tahoe-only", minOS: "26.0"),
                osBound("always", minOS: nil),
            ]),
            appVersion: "1.0",
            osVersion: "15.6.1"
        )

        // A path that only exists on a later release would otherwise be
        // reported as missing on every Mac that has not got there yet.
        #expect(store.definitions().map(\.id) == ["always"])
    }

    @Test("A rule for a retired location goes quiet on newer systems")
    func retiredRulesStopApplying() {
        let rules = [osBound("sequoia-only", maxOS: "15.9"), osBound("always")]

        #expect(
            DefinitionStore(source: StubSource(rules: rules), appVersion: "1.0", osVersion: "15.6.1")
                .definitions().map(\.id) == ["sequoia-only", "always"]
        )
        #expect(
            DefinitionStore(source: StubSource(rules: rules), appVersion: "1.0", osVersion: "26.0")
                .definitions().map(\.id) == ["always"]
        )
    }

    @Test("Both bounds are inclusive, and compared numerically")
    func osBoundsAreInclusiveAndNumeric() {
        let rule = osBound("window", minOS: "15.0", maxOS: "15.10")

        func applies(on osVersion: String) -> Bool {
            DefinitionStore(source: StubSource(rules: [rule]), appVersion: "1.0", osVersion: osVersion)
                .applies(rule)
        }

        #expect(applies(on: "15.0"))
        #expect(applies(on: "15.10"))
        // 15.10 is newer than 15.9, which a plain string comparison gets wrong.
        #expect(applies(on: "15.9"))
        #expect(applies(on: "14.7") == false)
        #expect(applies(on: "26.0") == false)
    }

    @Test("Every shipped rule states the systems it is correct for, or applies to all")
    func shippedRulesDeclareTheirRange() {
        for rule in Catalogue.all {
            if let minimum = rule.minOSVersion, let maximum = rule.maxOSVersion {
                #expect(
                    minimum.compare(maximum, options: .numeric) != .orderedDescending,
                    "\(rule.id) has a range that excludes every system"
                )
            }
        }
    }

    @Test("The shipping app resolves a non-empty catalogue")
    func shippedStoreResolvesRules() {
        #expect(DefinitionStore().definitions().isEmpty == false)
        #expect(DefinitionStore.bundleVersion.isEmpty == false)
    }
}
