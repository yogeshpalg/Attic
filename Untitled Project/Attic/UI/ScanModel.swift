import Foundation
import Observation

@MainActor
@Observable
final class ScanModel {

    enum Phase: Equatable {
        case firstRun
        case scanning
        case review
    }

    struct Withheld: Identifiable {
        let id = UUID()
        let ruleID: String
        let count: Int
        let bytes: Int64
        let reason: WithheldReason
    }

    private(set) var phase: Phase = .firstRun
    private(set) var findings: [Finding] = []
    private(set) var unavailable: [(ruleID: String, reason: UnavailableReason)] = []
    /// What the rules deliberately left alone. Shown to the user, because
    /// "nothing found" and "withheld 1.15 GB on every scan" must not look alike.
    private(set) var withheld: [Withheld] = []
    /// Surfaced in the interface rather than logged. A non-empty list is a bug
    /// in a rule, and hiding it is how a destructive one would go unnoticed.
    private(set) var rejections: [(ruleID: String, path: String, reason: RejectionReason)] = []
    private(set) var spaceAtStart: VolumeSpace.Reading?
    private(set) var activeRuleIDs: Set<String> = []

    var selectedCategory: Category?

    private var scanTask: Task<Void, Never>?

    // MARK: - Derived

    var totalFound: Int64 { findings.reduce(0) { $0 + $1.allocatedSize } }

    var categoriesPresent: [Category] {
        Category.allCases.filter { category in
            findings.contains { $0.category == category }
        }
    }

    func total(in category: Category) -> Int64 {
        findings.filter { $0.category == category }.reduce(0) { $0 + $1.allocatedSize }
    }

    func findings(in category: Category?) -> [Finding] {
        let scoped = category.map { c in findings.filter { $0.category == c } } ?? findings
        // Staleness before size: size tells you where the bytes are, staleness
        // tells you which ones you will not miss.
        return scoped.sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?) where l != r: l < r
            default: lhs.allocatedSize > rhs.allocatedSize
            }
        }
    }

    // MARK: - Actions

    func startScan() {
        scanTask?.cancel()
        findings = []
        unavailable = []
        withheld = []
        rejections = []
        activeRuleIDs = []
        spaceAtStart = VolumeSpace.read()
        phase = .scanning

        let definitions = DefinitionStore().definitions()
        let engine = ScanEngine(definitions: definitions)

        scanTask = Task { [weak self] in
            for await event in engine.run() {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
            guard let self, !Task.isCancelled else { return }
            self.phase = .review
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = findings.isEmpty ? .firstRun : .review
    }

    private func apply(_ event: ScanEvent) {
        switch event {
        case .began(let ruleID):
            activeRuleIDs.insert(ruleID)
        case .completed(let ruleID):
            activeRuleIDs.remove(ruleID)
        case .found(let finding):
            findings.append(finding)
        case .withheld(let ruleID, let count, let bytes, let reason):
            withheld.append(Withheld(ruleID: ruleID, count: count, bytes: bytes, reason: reason))
        case .unavailable(let ruleID, let reason):
            unavailable.append((ruleID, reason))
        case .rejected(let ruleID, let path, let reason):
            rejections.append((ruleID, path, reason))
        }
    }

    // MARK: - Verification

    /// Builds a `du` command covering every path found, so the reported figures
    /// can be checked against the system's own accounting. This is how stage one
    /// gets verified; nothing in the app shells out.
    func verificationCommand(for category: Category?) -> String {
        let paths = findings(in: category)
            .flatMap(\.paths)
            .map { "'\($0.path)'" }
        guard !paths.isEmpty else { return "" }
        return "du -sch \\\n  " + paths.joined(separator: " \\\n  ")
    }
}
