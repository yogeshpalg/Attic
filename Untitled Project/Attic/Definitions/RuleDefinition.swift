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
    /// Every file anywhere beneath the root with this extension.
    case filesWithExtension(String)
}

/// Typed exclusions, for the same reason as `MatchSpec`.
enum ExcludeRule: Codable, Sendable, Equatable {
    /// Any path with a component of this exact name, relative to the root.
    case pathComponent(String)
    case fileExtension(String)
    case nameSuffix(String)
}

enum Grouping: String, Codable, Sendable {
    /// Every match collapses into a single finding.
    case single
    /// One finding per match.
    case perMatch
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
    case lastModified
    case fileCount
    case supersededBuild
}

/// One catalogue entry. This is the unit that will be fetched from the public
/// definitions repository; for now the catalogue is compiled in.
struct RuleDefinition: Codable, Sendable, Identifiable, Equatable {
    let id: String
    /// Rules can ship ahead of the app that understands them.
    let minAppVersion: String
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
    let status: RuleStatus
    let explanation: Explanation
}
