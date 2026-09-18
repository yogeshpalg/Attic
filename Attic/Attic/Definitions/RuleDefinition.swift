import Foundation

/// Where a rule is allowed to look. Home-relative is the normal case; the engine
/// expands it once, so a definition never carries an absolute user path.
enum PathSpec: Codable, Sendable, Equatable {
    case home(String)
    case absolute(String)

    var url: URL {
        switch self {
        case .home(let relative):
            FileManager.default.homeDirectoryForCurrentUser.appending(path: relative)
        case .absolute(let path):
            URL(fileURLWithPath: path)
        }
    }
}

/// What inside the root the rule matches. Deliberately a closed set rather than a
/// glob string: there is no pattern engine to get subtly wrong, and a malformed
/// definition cannot widen its own blast radius.
enum MatchSpec: Codable, Sendable, Equatable {
    /// The root directory itself, as one item.
    case wholeRoot
    /// Each immediate subdirectory of the root, as its own item.
    case immediateChildren
    /// Only these immediate children, by exact name. Used where a directory mixes
    /// per-project folders with shared caches that need different copy and a
    /// different retention rule.
    case namedChildren([String])
    /// Immediate children whose name begins with one of these.
    ///
    /// Still not a pattern engine — a prefix cannot widen a rule's blast radius
    /// the way a glob can. It exists because Apple names each macOS installer
    /// after its release, so an exact list would go stale the day the next one
    /// ships, and a stale list quietly stops finding fifteen gigabytes.
    case childrenWithPrefix([String])
    /// Every file anywhere beneath the root with this extension.
    case filesWithExtension(String)
    /// Every file beneath the root that lives in iCloud and also has a copy on
    /// this Mac. Matching on a resource value rather than a name, because
    /// "is it taking up local space" is not something a path can tell you.
    case downloadedCloudFiles
    /// Support files whose owner is no longer on the Mac. Matched by bundle
    /// identifier rather than by path, so this one asks LaunchServices rather
    /// than the filesystem whether the owner is still around. The kind decides
    /// whether an app's leftovers or a tool's caches are wanted, which are two
    /// different things to say to someone.
    case orphanedSupport(OrphanScope)
}

/// Mirrors `SystemSupport.Architecture` in a form a definition can carry.
enum ArchitectureScope: String, Codable, Sendable {
    case appleSilicon
    case intel
}

/// Mirrors `Orphan.Kind` in a form a definition can carry.
enum OrphanScope: String, Codable, Sendable {
    case application
    case tool
}

/// Typed exclusions, for the same reason as `MatchSpec`.
enum ExcludeRule: Codable, Sendable, Equatable {
    /// Any path with a component of this exact name, relative to the root.
    case pathComponent(String)
    case fileExtension(String)
    case nameSuffix(String)
    /// Anything named after a bundle identifier. These belong to the rules that
    /// match by identifier, and this is what keeps a folder sweep from claiming
    /// the same bytes twice.
    case bundleIdentifierNames
}

enum Grouping: String, Codable, Sendable {
    /// Every match collapses into a single finding.
    case single
    /// One finding per match.
    case perMatch
    /// One finding per owning thing, for matches that know who they belong to.
    /// Leftovers from one uninstalled app are scattered across nine folders and
    /// are one decision, not nine.
    case perOwner
}

/// Which matches a rule declines to offer even though they matched. Whatever is
/// withheld is reported to the user, never silently dropped.
enum Retention: Codable, Sendable, Equatable {
    case none
    /// Leave anything touched recently alone — a project built this week is live.
    /// Never apply this to a directory written on every build; it would hide it forever.
    case excludeModifiedWithin(days: Int)
    /// Group children by the text before the first space and keep the newest in
    /// each group. Device support folders are named `iPhone17,2 27.0 (24A437)`,
    /// so the leading component is the device and everything after it varies per
    /// OS release — grouping any later than that would put two iOS versions of
    /// one phone into separate groups and offer neither.
    case keepNewestPerLeadingComponent
}

/// A cheap precondition checked before walking anything.
enum Applicability: Codable, Sendable, Equatable {
    case rootExists
    case xcodeInstalled
}

/// How the subtitle is phrased. Copy stays data-driven rather than hardcoded
/// per scanner, so a definition update can change wording without a code change.
enum SubtitleStyle: String, Codable, Sendable {
    /// "last built …" — for build output, where the date is a build.
    case lastModified
    /// "last used …" — for a cache, where the date is the last time anything
    /// touched it. Saying "last built" about Logic's cache was Xcode's language
    /// escaping into rules that have nothing to do with building.
    case lastUsed
    case fileCount
    case supersededBuild
}

/// One catalogue entry. This is the unit that will be fetched from the public
/// definitions repository; for now the catalogue is compiled in.
struct RuleDefinition: Codable, Sendable, Identifiable, Equatable {
    let id: String
    /// Rules can ship ahead of the app that understands them.
    let minAppVersion: String
    /// The oldest macOS this rule is correct for, if it is not correct for all
    /// of them. Apple moves things between releases — a cache that lived in one
    /// folder on Sequoia may live in another on Tahoe — and a rule pointed at
    /// the wrong one either finds nothing or, worse, finds something else.
    ///
    /// Left empty for every rule whose location has been stable, which is most
    /// of them. A version is stated only where the truth actually changed.
    var minOSVersion: String?
    /// The last macOS this rule is correct for. Set when a location is retired,
    /// so the rule goes quiet on newer systems instead of guessing.
    var maxOSVersion: String?
    /// Which Macs a rule applies to, when it does not apply to both.
    ///
    /// Left empty for almost everything: a cache is a cache on either
    /// architecture. It exists because some locations only exist on one — the
    /// Rosetta translation cache and the on-device model assets are Apple
    /// silicon only, and a rule for either on an Intel Mac would report
    /// "found nothing" about a folder that was never going to be there.
    var architecture: ArchitectureScope?
    let category: Category
    let displayName: String
    let root: PathSpec
    let match: MatchSpec
    let exclude: [ExcludeRule]
    let grouping: Grouping
    let retention: Retention
    let subtitleStyle: SubtitleStyle
    let applicability: Applicability
    let action: RemovalAction
    let privilege: Privilege
    let grade: SafetyGrade
    /// True when what this rule matches is *authored* — history somebody
    /// accumulated, or an artefact built locally that exists nowhere else.
    ///
    /// A cache is safe because the tool rebuilds it. Conversation history with a
    /// coding assistant is not a cache: nothing regenerates it, and losing it
    /// costs the context behind however many projects it covered. Rules marked
    /// here are not offered at all while the toolbar's "Work protected" toggle
    /// is on, which it is by default.
    var holdsAuthoredWork: Bool = false
    var status: RuleStatus
    let explanation: Explanation
}

// MARK: - Decoding a hand-written rule

extension RuleDefinition {

    /// Decoding written by hand, because the synthesised version does not use
    /// default values: a missing `holdsAuthoredWork` made Swift reject the whole
    /// file, and the error the author saw was "that file could not be read as a
    /// definitions catalogue" with no mention of which key.
    ///
    /// What is required and what defaults is a deliberate split. The fields that
    /// decide *what gets matched* and *what happens to it* are required, so a
    /// typo in `root` or `action` fails loudly instead of quietly becoming
    /// something else. The rest default to their cautious value.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required: get any of these wrong and the rule is not the rule the
        // author thought they wrote.
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(Category.self, forKey: .category)
        displayName = try container.decode(String.self, forKey: .displayName)
        root = try container.decode(PathSpec.self, forKey: .root)
        match = try container.decode(MatchSpec.self, forKey: .match)
        action = try container.decode(RemovalAction.self, forKey: .action)
        // The three sentences are the whole promise of the app.
        explanation = try container.decode(Explanation.self, forKey: .explanation)

        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "1.0"
        minOSVersion = try container.decodeIfPresent(String.self, forKey: .minOSVersion)
        maxOSVersion = try container.decodeIfPresent(String.self, forKey: .maxOSVersion)
        architecture = try container.decodeIfPresent(ArchitectureScope.self, forKey: .architecture)
        exclude = try container.decodeIfPresent([ExcludeRule].self, forKey: .exclude) ?? []
        grouping = try container.decodeIfPresent(Grouping.self, forKey: .grouping) ?? .single
        retention = try container.decodeIfPresent(Retention.self, forKey: .retention) ?? .none
        subtitleStyle = try container
            .decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? .fileCount
        applicability = try container
            .decodeIfPresent(Applicability.self, forKey: .applicability) ?? .rootExists
        privilege = try container.decodeIfPresent(Privilege.self, forKey: .privilege) ?? .user
        // Cautious where it costs nothing: an unstated grade is "check first",
        // so a rule nobody graded is never swept up by "Select safe".
        grade = try container.decodeIfPresent(SafetyGrade.self, forKey: .grade) ?? .checkFirst
        holdsAuthoredWork = try container
            .decodeIfPresent(Bool.self, forKey: .holdsAuthoredWork) ?? false
        status = try container.decodeIfPresent(RuleStatus.self, forKey: .status) ?? .active
    }
}
