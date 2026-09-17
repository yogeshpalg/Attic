import Foundation

/// Which Macs Attic's locations have actually been verified on, and what to say
/// when this Mac is not one of them.
///
/// The rules in the catalogue were checked against real directories on Apple
/// silicon. That is an honest limit, not a marketing one: a path that moved in a
/// release nobody tested, or that only exists on one architecture, produces a
/// rule that quietly finds nothing — and "found nothing" is indistinguishable
/// from "there is nothing" unless the app says otherwise.
enum SupportedSystems {

    /// The oldest release the catalogue has been verified against. Also the
    /// deployment target, so an older Mac cannot launch this build at all —
    /// the check stays here because the target is a build setting somebody may
    /// lower later, and the warning should appear rather than the assumption.
    static let testedFloor = 15

    /// The newest release verified. Raise this after checking the catalogue's
    /// paths on the new release — not when the release ships.
    static let testedCeiling = 27

    /// Apple silicon began here, so every release in the tested range runs on
    /// it. macOS 26 Tahoe is the last release to support Intel at all, and 27
    /// is Apple silicon only.
    static let firstAppleSiliconRelease = 11

    static let lastIntelRelease = 26

    /// Release names, for saying "macOS 26 Tahoe" rather than "macOS 26".
    static let names: [Int: String] = [
        11: "Big Sur",
        12: "Monterey",
        13: "Ventura",
        14: "Sonoma",
        15: "Sequoia",
        26: "Tahoe",
        27: "Golden Gate",
    ]

    static func name(for major: Int) -> String? { names[major] }
}

/// What this Mac is, and how well Attic knows it.
struct SystemSupport: Sendable, Equatable {

    enum Architecture: Sendable, Equatable {
        case appleSilicon
        case intel

        /// The same fact in the form a definition carries, so a rule and the
        /// machine can be compared without either side knowing about the other.
        var scope: ArchitectureScope {
            switch self {
            case .appleSilicon: .appleSilicon
            case .intel: .intel
            }
        }
    }

    /// Ordered by how much it changes what the user should expect.
    enum Standing: Sendable, Equatable {
        /// Apple silicon, within the verified release range.
        case verified
        /// A release newer than anything the catalogue was checked against.
        case untestedRelease
        /// A release older than anything the catalogue was checked against.
        case unsupportedRelease
        /// An Intel Mac. Supported, but not where the locations were verified.
        case legacyArchitecture
    }

    let osVersion: String
    let architecture: Architecture

    init(
        osVersion: String = DefinitionStore.systemVersion,
        architecture: Architecture = SystemSupport.currentArchitecture()
    ) {
        self.osVersion = osVersion
        self.architecture = architecture
    }

    var majorVersion: Int {
        Int(osVersion.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    /// "macOS 27 Golden Gate", or just the number for a release this build has
    /// never heard of. Guessing a name would be worse than omitting one.
    var releaseDescription: String {
        guard let name = SupportedSystems.name(for: majorVersion) else {
            return "macOS \(osVersion)"
        }
        return "macOS \(majorVersion) \(name)"
    }

    /// Release age is checked before architecture: an Intel Mac on a release
    /// nobody tested has the bigger problem of the two.
    var standing: Standing {
        if majorVersion < SupportedSystems.testedFloor { return .unsupportedRelease }
        if majorVersion > SupportedSystems.testedCeiling { return .untestedRelease }
        if architecture == .intel { return .legacyArchitecture }
        return .verified
    }

    var isFullyVerified: Bool { standing == .verified }

    /// One sentence for the notices list, or `nil` when there is nothing to
    /// warn about. Every one of these ends the same way on purpose: the gates
    /// still run, so the cost of Attic not knowing a location is a rule that
    /// finds nothing, never a rule that removes the wrong thing.
    var warning: String? {
        switch standing {
        case .verified:
            nil
        case .untestedRelease:
            """
            \(releaseDescription) is newer than any release Attic's locations \
            have been checked against, so some rules may find nothing here. \
            A definitions update corrects locations Apple has moved, without \
            waiting for a new version of the app.
            """
        case .unsupportedRelease:
            """
            \(releaseDescription) is older than any release Attic's locations \
            have been checked against. Some rules will look in the wrong place \
            and find nothing. Nothing is removed that Attic cannot verify first.
            """
        case .legacyArchitecture:
            """
            This is an Intel Mac. Attic's locations were verified on Apple \
            silicon, and a few of them differ here, so some rules may find \
            nothing. macOS \(SupportedSystems.lastIntelRelease) \
            \(SupportedSystems.name(for: SupportedSystems.lastIntelRelease) ?? "") \
            is the last release Apple supports on Intel.
            """
        }
    }

    // MARK: - Detection

    /// Asked of the hardware rather than the binary.
    ///
    /// `#if arch(...)` would describe the slice that happens to be running, and
    /// a universal app translated by Rosetta would then report an Intel Mac
    /// while sitting on Apple silicon. `hw.optional.arm64` answers for the
    /// machine.
    static func currentArchitecture() -> Architecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1 ? .appleSilicon : .intel
    }
}
