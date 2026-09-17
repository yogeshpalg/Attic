import Foundation

/// What actually happened to one path.
enum RemovalOutcome: Sendable, Equatable, Identifiable {
    /// Moved to the Trash. `recoveredFrom` is where it now sits, so the receipt
    /// can point at it.
    case trashed(path: String, bytes: Int64, inTrashAt: URL?)
    /// The local copy was dropped; the file itself is still in iCloud.
    case evicted(path: String, bytes: Int64)
    /// An allowlisted command ran. The space it freed is the tool's business,
    /// not something Attic measured, so no byte count is claimed.
    case ran(command: KnownCommand, output: String)
    case revealed(path: String)
    /// Failed a gate at the moment of removal, having passed it during the scan.
    case refused(path: String, reason: RejectionReason)
    case vanished(path: String)
    /// The filesystem said no. The message is whatever it said.
    case failed(path: String, message: String)

    var id: String {
        switch self {
        case .trashed(let path, _, _): "trashed:\(path)"
        case .evicted(let path, _): "evicted:\(path)"
        case .ran(let command, _): "ran:\(command.displayForm)"
        case .revealed(let path): "revealed:\(path)"
        case .refused(let path, _): "refused:\(path)"
        case .vanished(let path): "vanished:\(path)"
        case .failed(let path, _): "failed:\(path)"
        }
    }

    var loggedLine: String {
        switch self {
        case .trashed(let path, let bytes, _): "TRASHED  \(ByteFormat.string(bytes))\t\(path)"
        case .evicted(let path, let bytes): "EVICTED  \(ByteFormat.string(bytes))\t\(path)"
        case .ran(let command, _): "RAN      \(command.displayForm)"
        case .revealed(let path): "REVEALED \(path)"
        case .refused(let path, let reason): "REFUSED  \(reason.message)\t\(path)"
        case .vanished(let path): "VANISHED \(path)"
        case .failed(let path, let message): "FAILED   \(message)\t\(path)"
        }
    }
}

/// The record of a removal, kept so the interface can say what it did rather than
/// just claiming success.
struct RemovalReceipt: Sendable, Equatable {

    let outcomes: [RemovalOutcome]
    /// True when the batch was rejected before anything was touched.
    let wasAbandoned: Bool

    static let abandoned = RemovalReceipt(outcomes: [], wasAbandoned: true)

    /// Space that came back, whether by moving a file out or by dropping a local
    /// copy of one that stays in iCloud.
    var bytesTrashed: Int64 {
        outcomes.reduce(0) { total, outcome in
            switch outcome {
            case .trashed(_, let bytes, _), .evicted(_, let bytes): total + bytes
            case .ran, .revealed, .refused, .vanished, .failed: total
            }
        }
    }

    var trashedCount: Int {
        outcomes.filter {
            switch $0 {
            case .trashed, .evicted: true
            case .ran, .revealed, .refused, .vanished, .failed: false
            }
        }.count
    }

    var commandsRun: [RemovalOutcome] {
        outcomes.filter { if case .ran = $0 { true } else { false } }
    }

    var problems: [RemovalOutcome] {
        outcomes.filter {
            switch $0 {
            case .refused, .failed: true
            case .trashed, .evicted, .ran, .revealed, .vanished: false
            }
        }
    }

    var log: String { outcomes.map(\.loggedLine).joined(separator: "\n") }
}

/// Carries out a plan.
///
/// Everything here is recoverable by design: files go to the Trash rather than
/// being unlinked, so a wrong answer costs the user a drag back out of it rather
/// than their data. Nothing escalates — a path the user cannot remove themselves
/// is reported, not forced.
///
/// The gates are re-run per path immediately before the move, because the plan
/// the user approved was made before they read it.
struct RemovalExecutor: Sendable {

    let definitions: [RuleDefinition]
    /// Injected so tests can drive failures and so nothing here touches the real
    /// Trash unless it means to.
    let trash: @Sendable (URL) throws -> URL?
    let evict: @Sendable (URL) throws -> Void
    let runner: CommandRunner

    init(
        definitions: [RuleDefinition],
        trash: @Sendable @escaping (URL) throws -> URL? = RemovalExecutor.moveToTrash,
        evict: @Sendable @escaping (URL) throws -> Void = RemovalExecutor.evictCloudCopy,
        runner: CommandRunner = CommandRunner()
    ) {
        self.definitions = definitions
        self.trash = trash
        self.evict = evict
        self.runner = runner
    }

    static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Drops the local copy and leaves the file in iCloud. There is no Trash
    /// involved because nothing is deleted — opening the file fetches it again.
    static func evictCloudCopy(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    /// Plans, re-verifies, then acts. A plan carrying any refusal is abandoned
    /// whole: if one path in a batch turned out to be wrong, the safe assumption
    /// is that the scan behind it is wrong too.
    func execute(_ findings: [Finding]) -> RemovalReceipt {
        let plan = RemovalPlan.plan(for: findings, definitions: definitions)
        guard plan.isSafeToExecute else { return .abandoned }

        let rootsByRule = Dictionary(
            definitions.map { ($0.id, $0.root.url) },
            uniquingKeysWith: { first, _ in first }
        )
        var outcomes: [RemovalOutcome] = []

        for finding in findings {
            guard finding.isSelectable else {
                // Not removable by this app. Surfaced rather than dropped, the
                // same way the planner degrades it to Reveal.
                outcomes.append(contentsOf: finding.paths.map { .revealed(path: $0.path) })
                continue
            }

            switch finding.action {
            case .revealOnly:
                outcomes.append(contentsOf: finding.paths.map { .revealed(path: $0.path) })

            case .command(let command):
                // The tool is asked to clean up after itself. Attic does not
                // touch the files: it has no idea which of them the tool still
                // needs, and the tool does.
                do {
                    let result = try runner(command)
                    if result.succeeded {
                        outcomes.append(.ran(command: command, output: result.output))
                    } else {
                        outcomes.append(.failed(
                            path: command.displayForm,
                            message: result.output.isEmpty
                                ? "exited with code \(result.exitCode)"
                                : result.output
                        ))
                    }
                } catch {
                    outcomes.append(
                        .failed(path: command.displayForm, message: error.localizedDescription)
                    )
                }

            case .trash:
                for path in finding.paths {
                    outcomes.append(remove(path, root: rootsByRule[finding.ruleID]))
                }

            case .evictCloudCopy:
                for path in finding.paths {
                    outcomes.append(evictCopy(path, root: rootsByRule[finding.ruleID]))
                }
            }
        }

        return RemovalReceipt(outcomes: outcomes, wasAbandoned: false)
    }

    private func remove(_ path: URL, root: URL?) -> RemovalOutcome {
        // Third and final check, immediately before the move.
        if let rejection = RemovalGate.rejection(for: path, root: root) {
            return .refused(path: path.path, reason: rejection)
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .vanished(path: path.path)
        }

        // Measured before the move, because afterwards there is nothing to measure.
        let bytes = DiskMeasure.measure(path).allocatedSize

        do {
            let moved = try trash(path)
            return .trashed(path: path.path, bytes: bytes, inTrashAt: moved)
        } catch {
            return .failed(path: path.path, message: error.localizedDescription)
        }
    }

    private func evictCopy(_ path: URL, root: URL?) -> RemovalOutcome {
        if let rejection = RemovalGate.rejection(for: path, root: root) {
            return .refused(path: path.path, reason: rejection)
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .vanished(path: path.path)
        }

        let bytes = DiskMeasure.measure(path).allocatedSize

        do {
            try evict(path)
            return .evicted(path: path.path, bytes: bytes)
        } catch {
            return .failed(path: path.path, message: error.localizedDescription)
        }
    }
}
