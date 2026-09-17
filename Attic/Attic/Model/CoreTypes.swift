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

    /// A glyph alongside the word, so the grade survives being read at a glance
    /// and does not rely on colour alone.
    var symbol: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .checkFirst: "exclamationmark.triangle.fill"
        case .keep: "lock.fill"
        }
    }
}

/// User-facing grouping. Developer categories only render when at least one of
/// their rules is applicable, so a Mac without Xcode never shows them.
enum Category: String, Codable, Sendable, CaseIterable, Identifiable {
    case installers
    /// Support files whose app is gone. Its own category because it is the one
    /// thing here people come looking for by name — an uninstaller — and filing
    /// it under "old and unused" hid a whole feature in plain sight.
    case removedApps
    case oldAndUnused
    case cachesAndLogs
    case backups
    /// Files that live in iCloud and also keep a copy on this Mac. Removing the
    /// local copy is not deleting the file, so these are described differently.
    case cloudStorage
    case developerXcode
    case developerToolchains

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installers: "Installers"
        case .removedApps: "Left by removed apps"
        case .oldAndUnused: "Old and unused"
        case .cachesAndLogs: "Caches and logs"
        case .backups: "Backups"
        case .cloudStorage: "Kept in iCloud"
        case .developerXcode: "Developer files"
        case .developerToolchains: "Toolchains"
        }
    }

    var isDeveloper: Bool { self == .developerXcode || self == .developerToolchains }

    /// One glyph per category, chosen to read at sidebar size.
    ///
    /// Filled throughout and picked for silhouette rather than detail: at 13pt
    /// a wrench and a hammer are the same grey smudge, so each one here has a
    /// distinct outline you can tell apart without reading the label.
    var symbol: String {
        switch self {
        case .installers: "arrow.down.app.fill"
        // An app outline with nothing in it: the app is not here, its files are.
        case .removedApps: "app.dashed"
        case .oldAndUnused: "hourglass"
        case .cachesAndLogs: "shippingbox.fill"
        case .backups: "clock.arrow.2.circlepath"
        case .cloudStorage: "icloud.fill"
        case .developerXcode: "hammer.fill"
        case .developerToolchains: "cube.fill"
        }
    }
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

    /// The executable and its arguments, kept apart.
    ///
    /// This is the whole reason the allowlist is an enum: there is no shell, no
    /// string to quote and no way for a definition to smuggle one in. A runtime
    /// identifier or snapshot name arrives as a single argument, so a name
    /// containing a space or a semicolon is an argument, never a second command.
    var invocation: (executable: String, arguments: [String]) {
        switch self {
        case .simctlDeletePreviews:
            ("/usr/bin/xcrun", ["simctl", "--set", "previews", "delete", "all"])
        case .simctlDeleteUnavailable:
            ("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
        case .simctlRuntimeDelete(let identifier):
            ("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier])
        case .tmutilDeleteSnapshot(let name):
            ("/usr/bin/tmutil", ["deletelocalsnapshots", name])
        case .brewCleanup:
            ("/usr/bin/env", ["brew", "cleanup"])
        case .goCleanModcache:
            ("/usr/bin/env", ["go", "clean", "-modcache"])
        case .dockerPrune(let volumes):
            ("/usr/bin/env", ["docker", "system", "prune", "--force"] + (volumes ? ["--volumes"] : []))
        }
    }

    /// Whether the command can run without a person answering a prompt. Anything
    /// interactive would hang a background process forever, so the flags above
    /// are chosen to make each one answer for itself.
    var isNonInteractive: Bool { true }
}

enum RemovalAction: Codable, Sendable, Equatable {
    case trash
    case command(KnownCommand)
    case revealOnly
    /// Removes the local copy of a file that lives in iCloud, leaving the file
    /// itself in place. The least destructive thing Attic does: nothing is
    /// deleted, and opening the file downloads it again.
    case evictCloudCopy

    var displayForm: String {
        switch self {
        case .trash: "Moves the matched files to the Trash"
        case .command(let command): command.displayForm
        case .revealOnly: "Reveal in Finder — Attic will not remove this"
        case .evictCloudCopy: "Removes the copy on this Mac and keeps the file in iCloud"
        }
    }

    /// The same operation, phrased for a finding Attic is not offering to act on.
    /// A detect-only row saying "Moves the matched files to the Trash" claims
    /// something is about to happen when nothing is on offer at all.
    var conditionalForm: String {
        switch self {
        case .trash: "Would move the matched files to the Trash"
        case .command(let command): "Would run \(command.displayForm)"
        case .revealOnly: displayForm
        case .evictCloudCopy: "Would remove the copy on this Mac and keep the file in iCloud"
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
