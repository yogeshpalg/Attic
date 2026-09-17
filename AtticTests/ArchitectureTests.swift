import Foundation
import Testing

@testable import Untitled_Project

/// Rules that are only correct on one kind of Mac.
///
/// Most locations are the same on both architectures, so this applies to very
/// few rules — but the two it does apply to are the two biggest lumps of space
/// on an Apple silicon Mac, and a rule for either on an Intel Mac would report
/// "found nothing" about a folder that never existed there.
@Suite("A rule for one architecture stays out of the way on the other")
struct ArchitectureGatingTests {

    @Test("A rule with no architecture applies to both")
    func unscopedRulesApplyEverywhere() {
        let rule = RuleDefinition.fixture(root: anyRoot)

        #expect(store(.appleSilicon, [rule]).definitions().count == 1)
        #expect(store(.intel, [rule]).definitions().count == 1)
    }

    @Test("An Apple silicon rule is inert on Intel")
    func siliconRulesAreInertOnIntel() {
        var rule = RuleDefinition.fixture(id: "silicon.only", root: anyRoot)
        rule.architecture = .appleSilicon

        #expect(store(.appleSilicon, [rule]).definitions().map(\.id) == ["silicon.only"])
        #expect(store(.intel, [rule]).definitions().isEmpty)
    }

    @Test("An Intel rule is inert on Apple silicon")
    func intelRulesAreInertOnSilicon() {
        var rule = RuleDefinition.fixture(id: "intel.only", root: anyRoot)
        rule.architecture = .intel

        #expect(store(.intel, [rule]).definitions().map(\.id) == ["intel.only"])
        #expect(store(.appleSilicon, [rule]).definitions().isEmpty)
    }

    @Test("Architecture is checked alongside the version bounds, not instead of them")
    func architectureAndVersionBothApply() {
        var rule = RuleDefinition.fixture(id: "silicon.tahoe", root: anyRoot)
        rule.architecture = .appleSilicon
        rule.minOSVersion = "26.0"

        // Right architecture, release too old.
        #expect(
            DefinitionStore(
                source: Stub(rules: [rule]), appVersion: "1.0",
                osVersion: "15.6", architecture: .appleSilicon
            ).definitions().isEmpty
        )
        // Right release, wrong architecture.
        #expect(
            DefinitionStore(
                source: Stub(rules: [rule]), appVersion: "1.0",
                osVersion: "26.0", architecture: .intel
            ).definitions().isEmpty
        )
        // Both right.
        #expect(
            DefinitionStore(
                source: Stub(rules: [rule]), appVersion: "1.0",
                osVersion: "26.0", architecture: .appleSilicon
            ).definitions().count == 1
        )
    }

    @Test("The machine's architecture maps to the value a definition carries")
    func architectureMapsToScope() {
        #expect(SystemSupport.Architecture.appleSilicon.scope == .appleSilicon)
        #expect(SystemSupport.Architecture.intel.scope == .intel)
    }

    @Test("Nothing in the shipped catalogue is gated by architecture yet")
    func shippedRulesAreArchitectureNeutral() {
        // A cache is a cache on either machine. If this ever fails, the rule
        // that added a gate should be able to say why — the Rosetta cache and
        // the on-device models are the only locations found so far that differ,
        // and neither is removable, so neither is a rule.
        for rule in Catalogue.all {
            #expect(
                rule.architecture == nil,
                "\(rule.id) is gated by architecture — is that location really machine-specific?"
            )
        }
    }
}

/// The on-device model assets: measured, explained, never offered.
@Suite("On-device model assets are reported and never offered")
struct ModelAssetTests {

    @Test("Nothing is reported on an Intel Mac")
    func intelMacsSeeNothing() {
        // Apple Intelligence requires Apple silicon, so an empty row on an
        // Intel Mac would answer a question nobody asked.
        #expect(OnDeviceModelAssets.read(architecture: .intel) == nil)
    }

    @Test("A family directory name becomes something readable")
    func familyNamesAreReadable() {
        let family = OnDeviceModelAssets.Family(
            directoryName: "com_apple_MobileAsset_UAF_Siri_Understanding", bytes: 1024
        )
        #expect(family.readableName == "Siri Understanding")
    }

    @Test("The total is the sum, and the largest few lead")
    func totalsAndOrdering() {
        let assets = OnDeviceModelAssets(families: [
            .init(directoryName: "com_apple_MobileAsset_UAF_Small", bytes: 10),
            .init(directoryName: "com_apple_MobileAsset_UAF_Large", bytes: 100),
            .init(directoryName: "com_apple_MobileAsset_UAF_Medium", bytes: 50),
            .init(directoryName: "com_apple_MobileAsset_UAF_Tiny", bytes: 1),
        ])

        #expect(assets.bytes == 161)
        #expect(assets.isWorthShowing)
        #expect(assets.largestFamilies.map(\.readableName) == ["Large", "Medium", "Small"])
    }

    @Test("Empty means nothing to show rather than a zero row")
    func emptyIsNotShown() {
        #expect(OnDeviceModelAssets(families: []).isWorthShowing == false)
    }

    @Test("The explanation says outright that Attic cannot remove this")
    func explanationAdmitsTheLimit() {
        // The whole value of the row is the admission. If this sentence ever
        // softens into "needs an administrator", the row becomes the same lie
        // every other cleaner tells about this space.
        let explanation = OnDeviceModelAssets(families: []).explanation

        #expect(explanation.whatStopsWorking.contains("cannot remove"))
        #expect(explanation.whatStopsWorking.contains("System Integrity Protection"))
        #expect(explanation.doesItComeBack.isEmpty == false)
    }

    @Test("The settings deep link is well formed")
    func settingsLinkIsUsable() throws {
        // Read out of this Mac's own System Settings binary rather than a
        // published list, because the panes were reorganised in 26 and again
        // in 27 and a stale identifier silently opens the top level.
        let url = try #require(OnDeviceModelAssets.settingsURL)
        #expect(url.scheme == "x-apple.systempreferences")
    }

    @Test("On this Mac, the measurement either reports real bytes or nothing at all")
    func realMachineMeasurement() throws {
        // Deliberately loose: this runs on whatever machine the tests run on.
        // What it pins is that a returned report is never empty or zero — an
        // all-zero row would claim there is nothing when the answer is "not
        // measurable here".
        guard let assets = OnDeviceModelAssets.read() else { return }

        #expect(assets.families.isEmpty == false)
        #expect(assets.bytes > 0)
        #expect(assets.families.allSatisfy { $0.bytes > 0 })
    }
}

// MARK: - Harness

private var anyRoot: URL {
    URL(fileURLWithPath: "/tmp/attic-architecture-tests")
}

private struct Stub: DefinitionSource {
    let rules: [RuleDefinition]
    func load() throws -> [RuleDefinition] { rules }
}

private func store(
    _ architecture: SystemSupport.Architecture, _ rules: [RuleDefinition]
) -> DefinitionStore {
    DefinitionStore(
        source: Stub(rules: rules),
        appVersion: "1.0",
        osVersion: "\(SupportedSystems.testedCeiling).0",
        architecture: architecture
    )
}
