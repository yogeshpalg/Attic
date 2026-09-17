import Foundation
import Testing

@testable import Untitled_Project

/// Saying so when this Mac is not one of the Macs the rules were checked on.
///
/// A rule pointed at a location that moved, or that never existed on this
/// architecture, finds nothing — and "found nothing" reads as "there is
/// nothing" unless the app admits the difference. These tests pin that the
/// admission appears exactly when it should and stays out of the way otherwise.
@Suite("A Mac outside the verified range is told so")
struct SystemSupportTests {

    @Test("Apple silicon inside the tested range needs no warning")
    func verifiedMacIsQuiet() {
        let support = SystemSupport(osVersion: "27.0", architecture: .appleSilicon)

        #expect(support.standing == .verified)
        #expect(support.isFullyVerified)
        #expect(support.warning == nil)
    }

    @Test("Both ends of the tested range count as verified")
    func rangeIsInclusive() {
        for version in ["\(SupportedSystems.testedFloor).0", "\(SupportedSystems.testedCeiling).4"] {
            #expect(SystemSupport(osVersion: version, architecture: .appleSilicon).standing == .verified)
        }
    }

    @Test("A release newer than anything tested is flagged as untested")
    func newerReleaseIsFlagged() throws {
        let next = SupportedSystems.testedCeiling + 1
        let support = SystemSupport(osVersion: "\(next).0", architecture: .appleSilicon)

        #expect(support.standing == .untestedRelease)
        let warning = try #require(support.warning)
        // The warning has to point at the fix, not just the problem.
        #expect(warning.contains("definitions update"))
    }

    @Test("A release older than anything tested is flagged as unsupported")
    func olderReleaseIsFlagged() throws {
        let previous = SupportedSystems.testedFloor - 1
        let support = SystemSupport(osVersion: "\(previous).6", architecture: .appleSilicon)

        #expect(support.standing == .unsupportedRelease)
        #expect(try #require(support.warning).isEmpty == false)
    }

    @Test("An Intel Mac is supported but told that the locations were verified elsewhere")
    func intelMacIsFlagged() throws {
        let support = SystemSupport(osVersion: "26.1", architecture: .intel)

        #expect(support.standing == .legacyArchitecture)
        let warning = try #require(support.warning)
        #expect(warning.contains("Intel"))
        #expect(warning.contains("Tahoe"))
    }

    @Test("An untested release outweighs the architecture")
    func releaseAgeOutranksArchitecture() {
        // An Intel Mac on a release nobody checked has the bigger of the two
        // problems, and one warning is worth reading where two are not.
        let support = SystemSupport(
            osVersion: "\(SupportedSystems.testedCeiling + 2).0", architecture: .intel
        )
        #expect(support.standing == .untestedRelease)
    }

    @Test("Releases are named where the name is known, and not guessed where it is not")
    func releasesAreNamedHonestly() {
        #expect(SystemSupport(osVersion: "15.6.1", architecture: .appleSilicon)
            .releaseDescription == "macOS 15 Sequoia")
        #expect(SystemSupport(osVersion: "26.0", architecture: .appleSilicon)
            .releaseDescription == "macOS 26 Tahoe")
        #expect(SystemSupport(osVersion: "27.0", architecture: .appleSilicon)
            .releaseDescription == "macOS 27 Golden Gate")
        // A release this build has never heard of gets its number, not a
        // made-up name.
        #expect(SystemSupport(osVersion: "31.2", architecture: .appleSilicon)
            .releaseDescription == "macOS 31.2")
    }

    @Test("A version string that makes no sense does not crash or pass as verified")
    func malformedVersionIsNotVerified() {
        #expect(SystemSupport(osVersion: "", architecture: .appleSilicon).standing == .unsupportedRelease)
        #expect(SystemSupport(osVersion: "banana", architecture: .appleSilicon).standing == .unsupportedRelease)
    }

    @Test("This Mac reports its own architecture")
    func realMachineIsDetected() {
        // Read from the hardware rather than the running slice, so a translated
        // binary does not report an Intel Mac while sitting on Apple silicon.
        let detected = SystemSupport.currentArchitecture()
        #expect(detected == .appleSilicon || detected == .intel)
    }

    @Test("Every release in the tested range runs on Apple silicon")
    func testedRangeIsAppleSiliconCapable() {
        // Apple silicon began at macOS 11, so a tested floor below that would
        // be claiming verification on machines that cannot exist.
        #expect(SupportedSystems.testedFloor >= SupportedSystems.firstAppleSiliconRelease)
        #expect(SupportedSystems.testedCeiling >= SupportedSystems.testedFloor)
        // macOS 26 Tahoe is the last release Apple supports on Intel.
        #expect(SupportedSystems.lastIntelRelease < SupportedSystems.testedCeiling)
    }
}
