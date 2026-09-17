import Foundation
@testable import Untitled_Project

/// A throwaway directory tree the scanners can be pointed at.
///
/// Deliberately built under the system temporary directory, which lives at
/// `/var/folders/…` and canonicalises to `/private/var/folders/…`. That means
/// every containment check in these suites is exercising real symlink
/// normalisation rather than a contrived case.
struct FixtureTree {

    let root: URL

    init(_ name: String = "attic-fixture") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A directory inside the tree whose contents actually live outside it.
    @discardableResult
    func symlink(_ relative: String, to destination: URL) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func setModified(_ url: URL, daysAgo: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86_400)],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - Rule construction

extension RuleDefinition {

    /// A minimal rule for pointing a scanner at a fixture. Everything the test
    /// is not exercising gets a harmless default.
    static func fixture(
        id: String = "test.rule",
        minAppVersion: String = "1.0",
        minOSVersion: String? = nil,
        maxOSVersion: String? = nil,
        category: Untitled_Project.Category = .developerXcode,
        root: URL,
        match: MatchSpec = .immediateChildren,
        exclude: [ExcludeRule] = [],
        grouping: Grouping = .perMatch,
        retention: Retention = .none,
        action: RemovalAction = .trash,
        privilege: Privilege = .user,
        grade: SafetyGrade = .safe,
        holdsAuthoredWork: Bool = false,
        status: RuleStatus = .active
    ) -> RuleDefinition {
        RuleDefinition(
            id: id,
            minAppVersion: minAppVersion,
            minOSVersion: minOSVersion,
            maxOSVersion: maxOSVersion,
            category: category,
            displayName: "Fixture",
            root: .absolute(root.path),
            match: match,
            exclude: exclude,
            grouping: grouping,
            retention: retention,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: action,
            privilege: privilege,
            grade: grade,
            holdsAuthoredWork: holdsAuthoredWork,
            status: status,
            explanation: Explanation(
                whatThisIs: "Fixture.",
                whatStopsWorking: "Nothing.",
                doesItComeBack: "Yes."
            )
        )
    }
}

// MARK: - Finding construction

extension Finding {

    /// A finding built directly, for the parts of the app that consume findings
    /// rather than produce them — the planner and the view model. Defaults describe
    /// the ordinary case: an active, safe, user-removable item.
    static func fixture(
        id: String = "test.rule.item",
        ruleID: String = "test.rule",
        // Qualified: Foundation exposes a `Category` of its own, so the bare name
        // is ambiguous from inside the test target.
        category: Untitled_Project.Category = .developerXcode,
        displayName: String = "Fixture item",
        subtitle: String = "4 files",
        paths: [URL],
        fileCount: Int = 1,
        allocatedSize: Int64 = 4096,
        lastUsed: Date? = nil,
        grade: SafetyGrade = .safe,
        action: RemovalAction = .trash,
        privilege: Privilege = .user,
        status: RuleStatus = .active
    ) -> Finding {
        Finding(
            id: id,
            ruleID: ruleID,
            category: category,
            displayName: displayName,
            subtitle: subtitle,
            paths: paths,
            fileCount: fileCount,
            allocatedSize: allocatedSize,
            lastUsed: lastUsed,
            grade: grade,
            action: action,
            privilege: privilege,
            explanation: Explanation(
                whatThisIs: "Fixture.",
                whatStopsWorking: "Nothing.",
                doesItComeBack: "Yes."
            ),
            status: status
        )
    }
}

// MARK: - Event collection

enum ScanProbe {

    struct Result {
        var findings: [Finding] = []
        var withheld: [(count: Int, bytes: Int64, reason: WithheldReason)] = []
        var rejected: [(path: String, reason: RejectionReason)] = []
        var unavailable: [UnavailableReason] = []
    }

    static func run(_ definitions: [RuleDefinition]) async -> Result {
        var result = Result()
        for await event in ScanEngine(definitions: definitions).run() {
            switch event {
            case .found(let finding):
                result.findings.append(finding)
            case .withheld(_, let count, let bytes, let reason):
                result.withheld.append((count, bytes, reason))
            case .rejected(_, let path, let reason):
                result.rejected.append((path, reason))
            case .unavailable(_, let reason):
                result.unavailable.append(reason)
            case .began, .completed:
                break
            }
        }
        return result
    }
}
