import Foundation

/// How risky it is to remove a finding. Drives the copy, the sort order, and
/// whether a checkbox is offered at all.
enum SafetyGrade: String, Codable, Sendable, CaseIterable {
    /// Regenerates on demand. No decision required beyond ticking it.
    case safe
    /// Costs time, bandwidth or a rebuild to restore. Never bulk-selected.
    case checkFirst
    /// Shown with its size and an explanation, but never removable by Attic.
    case keep

    var label: String {
        switch self {
        case .safe: "Safe"
        case .checkFirst: "Check first"
        case .keep: "Keep"
        }
    }
}

/// User-facing grouping. Developer categories only render when at least one of
/// their rules is applicable, so a Mac without Xcode never shows them.
enum Category: String, Codable, Sendable, CaseIterable, Identifiable {
    case installers
    case oldAndUnused
    case cachesAndLogs
    case backups
    case developerXcode
    case developerToolchains

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installers: "Installers"
        case .oldAndUnused: "Old and unused"
        case .cachesAndLogs: "Caches and logs"
        case .backups: "Backups"
        case .developerXcode: "Developer files"
        case .developerToolchains: "Toolchains"
        }
    }

    var isDeveloper: Bool { self == .developerXcode || self == .developerToolchains }
}

/// The three sentences that are the whole point of the app. Written for someone
/// who has never heard of DerivedData.
struct Explanation: Codable, Sendable, Equatable {
    let whatThisIs: String
    let whatStopsWorking: String
    let doesItComeBack: String
}

/// The compiled allowlist of commands Attic is ever permitted to run. No shell
/// string originates from data — a definition can only name a case of this enum.
/// Nothing executes these in this build; there is no process runner yet.
enum KnownCommand: Codable, Sendable, Equatable {
    case simctlDeletePreviews
    case simctlDeleteUnavailable
    /// Runtimes live under root-owned `/Library`, so removal goes through simctl
    /// rather than a file operation that would fail with EPERM.
    case simctlRuntimeDelete(identifier: String)
    case tmutilDeleteSnapshot(name: String)
    case brewCleanup
    case goCleanModcache
    case dockerPrune(volumes: Bool)

    /// Shown verbatim in the expanded row, so the exact operation is visible
    /// before anything is ticked.
    var displayForm: String {
        switch self {
        case .simctlDeletePreviews: "xcrun simctl --set previews delete all"
        case .simctlDeleteUnavailable: "xcrun simctl delete unavailable"
        case .simctlRuntimeDelete(let identifier): "xcrun simctl runtime delete \(identifier)"
        case .tmutilDeleteSnapshot(let name): "tmutil deletelocalsnapshots \(name)"
        case .brewCleanup: "brew cleanup"
        case .goCleanModcache: "go clean -modcache"
        case .dockerPrune(let volumes): "docker system prune\(volumes ? " --volumes" : "")"
        }
    }
}

enum RemovalAction: Codable, Sendable, Equatable {
    case trash
    case command(KnownCommand)
    case revealOnly

    var displayForm: String {
        switch self {
        case .trash: "Moves the matched files to the Trash"
        case .command(let command): command.displayForm
        case .revealOnly: "Reveal in Finder — Attic will not remove this"
        }
    }
}

/// Whether the action can be carried out by the app running as the user.
/// Attic never escalates: an `administrator` finding degrades to Reveal in Finder
/// rather than installing a privileged helper.
enum Privilege: String, Codable, Sendable {
    case user
    case administrator
}

/// A newly drafted rule ships as `detectOnly`: it reports its size and
/// explanation but offers no checkbox until a later release promotes it.
enum RuleStatus: String, Codable, Sendable {
    case detectOnly
    case active
}
