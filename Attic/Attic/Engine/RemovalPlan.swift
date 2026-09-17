import Foundation

/// One intended operation. Producing these performs nothing — the plan is the
/// dry run, and in this build it is the only thing that exists. There is no
/// executor, so a plan cannot be carried out even by mistake.
enum PlannedOperation: Sendable, Equatable {
    case trash(url: URL, bytes: Int64)
    case run(KnownCommand)
    case reveal(url: URL)
    /// Drop the local copy of a file that stays in iCloud.
    case evict(url: URL, bytes: Int64)
    /// A path that passed every gate during the scan and fails one now.
    case refuse(path: String, reason: RejectionReason)
    /// Gone between the scan and the plan. Common with DerivedData.
    case missing(path: String)
    /// Trashed, but a different size than the scan reported.
    ///
    /// Carries both figures because the difference is the user's business: they
    /// ticked a row saying 400 MB and 900 MB is about to move. The operation
    /// still happens — a size change is not grounds to refuse something
    /// somebody chose — and `bytes` is what will actually be removed.
    case resized(url: URL, scanned: Int64, bytes: Int64)

    var loggedLine: String {
        switch self {
        case .trash(let url, let bytes):
            "TRASH    \(ByteFormat.string(bytes))\t\(url.path)"
        case .run(let command):
            "RUN      \(command.displayForm)"
        case .reveal(let url):
            "REVEAL   \(url.path)"
        case .evict(let url, let bytes):
            "EVICT    \(ByteFormat.string(bytes))\t\(url.path)"
        case .refuse(let path, let reason):
            "REFUSE   \(reason.message)\t\(path)"
        case .missing(let path):
            "MISSING  \(path)"
        case .resized(let url, let scanned, let bytes):
            "TRASH    \(ByteFormat.string(bytes))\t\(url.path)\t(scan said \(ByteFormat.string(scanned)))"
        }
    }
}

/// The two gates every path passes before anything happens to it: it must sit
/// inside the root its own rule declared, and it must clear the compiled denylist.
///
/// Deliberately shared by the planner and the executor, and deliberately run
/// twice. A person reads the explanations between those two moments, and Xcode
/// keeps writing while they do.
enum RemovalGate {

    static func rejection(for path: URL, root: URL?) -> RejectionReason? {
        guard let root else { return .outsideDeclaredRoot }
        guard PathContainment.contains(root: root, candidate: path) else {
            return .outsideDeclaredRoot
        }
        return Denylist.rejection(for: path)
    }
}

/// Turns a set of chosen findings into the exact list of operations that would
/// run, re-verifying every path at plan time rather than trusting the scan.
///
/// The re-verification is not paranoia: a scan of DerivedData can be minutes old
/// by the time someone finishes reading the explanations, and Xcode will have
/// rewritten it. Sizes are re-measured and containment is re-checked against the
/// authoritative compiled catalogue, not against anything carried on the finding.
struct RemovalPlan: Sendable {

    let operations: [PlannedOperation]

    /// Everything that will be moved to the Trash, including paths whose size
    /// changed since the scan. `resized` used to be left out of this list while
    /// its bytes still counted toward `bytesStaged`, so the plan promised space
    /// that nothing in it would actually reclaim.
    var trashOperations: [PlannedOperation] {
        operations.filter {
            switch $0 {
            case .trash, .resized: true
            default: false
            }
        }
    }

    /// Paths that moved, but not at the size the row said. Surfaced so the
    /// receipt can account for the difference instead of quietly absorbing it.
    var resizedOperations: [PlannedOperation] {
        operations.filter { if case .resized = $0 { true } else { false } }
    }
    var refusals: [PlannedOperation] { operations.filter { if case .refuse = $0 { true } else { false } } }

    /// What would actually be staged, using freshly measured sizes.
    var bytesStaged: Int64 {
        operations.reduce(0) { total, operation in
            switch operation {
            case .trash(_, let bytes): total + bytes
            case .evict(_, let bytes): total + bytes
            case .resized(_, _, let bytes): total + bytes
            default: total
            }
        }
    }

    /// A plan is only safe to run when nothing in it was refused.
    var isSafeToExecute: Bool { refusals.isEmpty }

    var dryRunLog: String {
        operations.map(\.loggedLine).joined(separator: "\n")
    }

    static func plan(for findings: [Finding], definitions: [RuleDefinition]) -> RemovalPlan {
        let rootsByRule = Dictionary(
            definitions.map { ($0.id, $0.root.url) },
            uniquingKeysWith: { first, _ in first }
        )
        var operations: [PlannedOperation] = []

        for finding in findings {
            guard finding.isSelectable else {
                // A `keep` or detect-only finding reaching the planner is a UI bug.
                // It degrades to Reveal rather than being silently dropped.
                operations.append(contentsOf: finding.paths.map { .reveal(url: $0) })
                continue
            }

            switch finding.action {
            case .revealOnly:
                operations.append(contentsOf: finding.paths.map { .reveal(url: $0) })

            case .command(let command):
                operations.append(.run(command))

            case .trash:
                let root = rootsByRule[finding.ruleID]

                for path in finding.paths {
                    // No catalogue entry means no declared root, so containment
                    // cannot be verified and the path is refused outright.
                    if let rejection = RemovalGate.rejection(for: path, root: root) {
                        operations.append(.refuse(path: path.path, reason: rejection))
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: path.path) else {
                        operations.append(.missing(path: path.path))
                        continue
                    }

                    let fresh = DiskMeasure.measure(path).allocatedSize
                    // Only a single-path finding can be compared: with several
                    // paths the finding's total says nothing about any one of
                    // them.
                    let scanned = finding.paths.count == 1 ? finding.allocatedSize : fresh
                    if scanned != fresh {
                        operations.append(.resized(url: path, scanned: scanned, bytes: fresh))
                    } else {
                        operations.append(.trash(url: path, bytes: fresh))
                    }
                }

            case .evictCloudCopy:
                let root = rootsByRule[finding.ruleID]

                // The same gates as a removal. Evicting is reversible, but it is
                // still the app reaching into a path it was told to stay out of
                // if containment or the denylist is wrong.
                for path in finding.paths {
                    if let rejection = RemovalGate.rejection(for: path, root: root) {
                        operations.append(.refuse(path: path.path, reason: rejection))
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: path.path) else {
                        operations.append(.missing(path: path.path))
                        continue
                    }
                    operations.append(
                        .evict(url: path, bytes: DiskMeasure.measure(path).allocatedSize)
                    )
                }
            }
        }

        return RemovalPlan(operations: operations)
    }
}
