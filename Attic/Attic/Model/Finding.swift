import Foundation

/// One reviewable item. `displayName` and `subtitle` are user-facing and never
/// contain a file path — paths belong in the expanded explanation only.
struct Finding: Identifiable, Sendable, Equatable {
    let id: String
    let ruleID: String
    let category: Category
    let displayName: String
    let subtitle: String
    let paths: [URL]
    let fileCount: Int
    /// Allocated size, summed from `totalFileAllocatedSize` so the figure tracks `du`.
    let allocatedSize: Int64
    let lastUsed: Date?
    let grade: SafetyGrade
    let action: RemovalAction
    let privilege: Privilege
    let explanation: Explanation
    let status: RuleStatus
    /// True when part of this could not be read, which means the size shown is a
    /// floor rather than the figure. Carried onto the finding so the interface
    /// can say so: a number that is quietly too small is worse than no number.
    var wasPartlyUnreadable: Bool = false
    /// True when this matched authored work — history, or something built here
    /// that exists nowhere else. With protection on it is shown and measured
    /// but never offered, and the row says which of the two it is.
    var holdsAuthoredWork: Bool = false

    /// A checkbox is offered only for active rules that Attic can actually act on.
    var isSelectable: Bool {
        grade != .keep && status == .active && privilege == .user && action != .revealOnly
    }
}

/// Why a whole rule produced nothing. Kept distinct from "found zero bytes" so the
/// UI can show the inline Full Disk Access row instead of silently omitting a category.
enum UnavailableReason: Sendable, Equatable {
    case softwareNotInstalled
    case rootMissing
    case emptyRoot
    /// The folder had contents, and this rule's own exclusions removed all of
    /// them. Distinct from `emptyRoot` because saying "the folder is empty"
    /// about a folder full of files is simply untrue, and it sends someone
    /// looking for a problem that is not there.
    case everythingExcluded
    case permissionDenied

    var message: String {
        switch self {
        case .softwareNotInstalled: "the software this looks for is not installed"
        case .rootMissing: "the folder this looks in does not exist on this Mac"
        case .emptyRoot: "the folder this looks in is empty"
        case .everythingExcluded: "everything in that folder is excluded by this rule"
        case .permissionDenied: "macOS denied access — Full Disk Access would be needed"
        }
    }
}

/// Matches a rule deliberately declined to offer. Reported rather than dropped:
/// a retention bug and a genuinely empty folder look identical otherwise, and
/// "found nothing" would quietly mean "hid 1.15 GB every single time".
enum WithheldReason: Sendable, Equatable {
    case touchedRecently(days: Int)
    case newestForItsDevice

    var message: String {
        switch self {
        case .touchedRecently(let days): "you have used them in the last \(days) days"
        case .newestForItsDevice: "they are the newest version for their device"
        }
    }
}

/// A path the engine refused to emit. Every rejection is surfaced rather than
/// swallowed: a rule that trips these is a bug in the rule, and we want to see it.
enum RejectionReason: Sendable, Equatable {
    case outsideDeclaredRoot
    case denylisted
    case protectedComponent

    var message: String {
        switch self {
        case .outsideDeclaredRoot: "resolved outside the rule's declared root"
        case .denylisted: "matched the compiled denylist"
        case .protectedComponent: "sits inside a protected directory"
        }
    }
}

enum ScanEvent: Sendable {
    case began(ruleID: String)
    case found(Finding)
    case withheld(ruleID: String, count: Int, bytes: Int64, reason: WithheldReason)
    case completed(ruleID: String)
    case unavailable(ruleID: String, reason: UnavailableReason)
    case rejected(ruleID: String, path: String, reason: RejectionReason)
}
