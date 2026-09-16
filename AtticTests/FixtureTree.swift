import Foundation
@testable import MyApp

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
        root: URL,
        match: MatchSpec = .immediateChildren,
        exclude: [ExcludeRule] = [],
        grouping: Grouping = .perMatch,
        retention: Retention = .none,
        action: RemovalAction = .trash,
        grade: SafetyGrade = .safe,
        status: RuleStatus = .active
    ) -> RuleDefinition {
        RuleDefinition(
            id: id,
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Fixture",
            root: .absolute(root.path),
            match: match,
            exclude: exclude,
            grouping: grouping,
            retention: retention,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: action,
            privilege: .user,
            grade: grade,
            status: status,
            explanation: Explanation(
                whatThisIs: "Fixture.",
                whatStopsWorking: "Nothing.",
                doesItComeBack: "Yes."
            )
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
