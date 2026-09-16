import Foundation

/// Executes one definition. Read-only: it stats and enumerates, and makes no
/// filesystem modification of any kind.
///
/// Every path this produces passes three gates before it is emitted — containment
/// inside the rule's declared root, the compiled denylist, and the rule's own
/// exclusions. A path that fails any of them is reported as a rejection rather
/// than quietly dropped, because a rule that trips a gate is a bug in the rule.
struct RuleScanner: Sendable {

    let definition: RuleDefinition

    private var root: URL { definition.root.url }

    // MARK: - Applicability

    func isApplicable() -> (Bool, UnavailableReason?) {
        switch definition.applicability {
        case .rootExists:
            guard FileManager.default.fileExists(atPath: root.path) else {
                return (false, .rootMissing)
            }
            return (true, nil)
        case .xcodeInstalled:
            let installed = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
            return (installed, installed ? nil : .softwareNotInstalled)
        }
    }

    // MARK: - Scan

    func scan(into continuation: AsyncStream<ScanEvent>.Continuation) {
        continuation.yield(.began(ruleID: definition.id))
        defer { continuation.yield(.completed(ruleID: definition.id)) }

        let (applicable, reason) = isApplicable()
        guard applicable else {
            continuation.yield(.unavailable(ruleID: definition.id, reason: reason ?? .rootMissing))
            return
        }

        // The root itself is gated first. A rule whose root is denylisted produces
        // nothing at all, whatever it claims to match.
        if let rejection = Denylist.rejection(for: root) {
            continuation.yield(.rejected(ruleID: definition.id, path: root.path, reason: rejection))
            return
        }

        let matches = gatherMatches(continuation: continuation)
        guard !matches.isEmpty else {
            continuation.yield(.unavailable(ruleID: definition.id, reason: .emptyRoot))
            return
        }

        let retained = applyRetention(to: matches, continuation: continuation)
        guard !retained.isEmpty else { return }

        switch definition.grouping {
        case .single:
            if let finding = makeSingleFinding(from: retained) {
                continuation.yield(.found(finding))
            }
        case .perMatch:
            for match in retained {
                if Task.isCancelled { return }
                if let finding = makePerMatchFinding(from: match) {
                    continuation.yield(.found(finding))
                }
            }
        }
    }

    // MARK: - Matching

    private struct Match: Sendable {
        let url: URL
        let reading: SizeReading
    }

    private func gatherMatches(continuation: AsyncStream<ScanEvent>.Continuation) -> [Match] {
        var candidates: [URL] = []

        switch definition.match {
        case .wholeRoot:
            candidates = [root]

        case .immediateChildren:
            candidates = directories(in: root)

        case .namedChildren(let names):
            candidates = directories(in: root).filter { names.contains($0.lastPathComponent) }

        case .filesWithExtension(let ext):
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { return [] }

            for case let file as URL in enumerator {
                if Task.isCancelled { return [] }
                guard file.pathExtension.caseInsensitiveCompare(ext) == .orderedSame else { continue }
                candidates.append(file)
            }
        }

        var matches: [Match] = []
        for candidate in candidates {
            if Task.isCancelled { return matches }

            guard PathContainment.contains(root: root, candidate: candidate) else {
                continuation.yield(.rejected(
                    ruleID: definition.id, path: candidate.path, reason: .outsideDeclaredRoot
                ))
                continue
            }
            if let rejection = Denylist.rejection(for: candidate) {
                continuation.yield(.rejected(
                    ruleID: definition.id, path: candidate.path, reason: rejection
                ))
                continue
            }
            guard !isExcluded(candidate) else { continue }

            let reading = DiskMeasure.measure(candidate) { Task.isCancelled }
            guard reading.allocatedSize > 0 || reading.fileCount > 0 else { continue }
            matches.append(Match(url: candidate, reading: reading))
        }
        return matches
    }

    private func directories(in url: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return (contents ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func isExcluded(_ url: URL) -> Bool {
        // Exclusions are evaluated against the portion of the path below the root,
        // so a component name that happens to appear in the user's home directory
        // path cannot accidentally exclude an entire rule.
        let rootDepth = PathContainment.canonical(root).pathComponents.count
        let relative = Array(PathContainment.canonical(url).pathComponents.dropFirst(rootDepth))

        for rule in definition.exclude {
            switch rule {
            case .pathComponent(let name):
                if relative.contains(name) { return true }
            case .fileExtension(let ext):
                if url.pathExtension.caseInsensitiveCompare(ext) == .orderedSame { return true }
            case .nameSuffix(let suffix):
                if url.lastPathComponent.hasSuffix(suffix) { return true }
            }
        }
        return false
    }

    // MARK: - Retention

    private func applyRetention(
        to matches: [Match],
        continuation: AsyncStream<ScanEvent>.Continuation
    ) -> [Match] {
        switch definition.retention {
        case .none:
            return matches

        case .excludeModifiedWithin(let days):
            let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86_400)
            let kept = matches.filter { ($0.reading.newestModification ?? .distantPast) >= cutoff }
            report(kept, .touchedRecently(days: days), continuation)
            return matches.filter { ($0.reading.newestModification ?? .distantPast) < cutoff }

        case .keepNewestPerLeadingComponent:
            let groups = Dictionary(grouping: matches) { match -> String in
                let name = match.url.lastPathComponent
                return name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
            }
            var offered: [Match] = []
            var kept: [Match] = []
            for group in groups.values {
                let sorted = group.sorted {
                    ($0.reading.newestModification ?? .distantPast)
                        < ($1.reading.newestModification ?? .distantPast)
                }
                if let newest = sorted.last { kept.append(newest) }
                offered.append(contentsOf: sorted.dropLast())
            }
            report(kept, .newestForItsDevice, continuation)
            return offered
        }
    }

    private func report(
        _ withheld: [Match],
        _ reason: WithheldReason,
        _ continuation: AsyncStream<ScanEvent>.Continuation
    ) {
        guard !withheld.isEmpty else { return }
        continuation.yield(.withheld(
            ruleID: definition.id,
            count: withheld.count,
            bytes: withheld.reduce(Int64(0)) { $0 + $1.reading.allocatedSize },
            reason: reason
        ))
    }

    // MARK: - Finding construction

    private func makeSingleFinding(from matches: [Match]) -> Finding? {
        let reading = matches.map(\.reading).reduce(SizeReading(), +)
        guard reading.allocatedSize > 0 else { return nil }
        return Finding(
            id: definition.id,
            ruleID: definition.id,
            category: definition.category,
            displayName: definition.displayName,
            subtitle: subtitle(for: reading),
            paths: matches.map(\.url),
            fileCount: reading.fileCount,
            allocatedSize: reading.allocatedSize,
            lastUsed: reading.newestModification,
            grade: definition.grade,
            action: definition.action,
            privilege: definition.privilege,
            explanation: definition.explanation,
            status: definition.status
        )
    }

    private func makePerMatchFinding(from match: Match) -> Finding? {
        guard match.reading.allocatedSize > 0 else { return nil }
        return Finding(
            id: "\(definition.id).\(match.url.lastPathComponent)",
            ruleID: definition.id,
            category: definition.category,
            displayName: friendlyName(for: match.url),
            subtitle: subtitle(for: match.reading),
            paths: [match.url],
            fileCount: match.reading.fileCount,
            allocatedSize: match.reading.allocatedSize,
            lastUsed: match.reading.newestModification,
            grade: definition.grade,
            action: definition.action,
            privilege: definition.privilege,
            explanation: definition.explanation,
            status: definition.status
        )
    }

    /// DerivedData folders are named `MyProject-abcdefghijklmn`. The hash is noise
    /// to a person, so it is dropped from the display name.
    private func friendlyName(for url: URL) -> String {
        let name = url.lastPathComponent
        guard case .immediateChildren = definition.match else { return name }
        if let dash = name.lastIndex(of: "-"),
           name[name.index(after: dash)...].count >= 20 {
            return String(name[name.startIndex..<dash])
        }
        return name
    }

    private func subtitle(for reading: SizeReading) -> String {
        switch definition.subtitleStyle {
        case .lastModified:
            guard let modified = reading.newestModification else { return "no recorded activity" }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            return "last built \(relative.localizedString(for: modified, relativeTo: Date()))"

        case .fileCount:
            let files = reading.fileCount
            return files == 1 ? "1 file" : "\(files.formatted(.number)) files"

        case .supersededBuild:
            return "an older version · your newest one is kept"
        }
    }
}
