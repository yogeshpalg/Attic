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

        // The root itself is gated first. A rule rooted inside a protected path
        // produces nothing at all and enumerates nothing, whatever it claims to
        // match. Rooting *above* one is allowed — every candidate is still
        // checked in both directions below, including a `wholeRoot` rule's own
        // root — so a scan can cover ~/Library without being able to touch the
        // device backups inside it.
        if let rejection = Denylist.scanRejection(for: root) {
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

        // A match that measured nothing because nothing could be read makes no
        // useful row — "0 bytes" is not an offer. It is reported at the rule
        // level instead, so a folder the user could unlock is never passed over
        // in silence, and the rest of the rule still reports normally.
        if retained.contains(where: { $0.reading.allocatedSize == 0 && $0.reading.encounteredDenial }) {
            continuation.yield(.unavailable(ruleID: definition.id, reason: .permissionDenied))
        }

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
        case .perOwner:
            // Matches with no owner would silently vanish here, so they fall back
            // to being their own group rather than being dropped.
            let groups = Dictionary(grouping: retained) { $0.owner ?? $0.url.path }
            for key in groups.keys.sorted() {
                if Task.isCancelled { return }
                if let finding = makeOwnerFinding(from: groups[key] ?? [], owner: key) {
                    continuation.yield(.found(finding))
                }
            }
        }
    }

    // MARK: - Matching

    private struct Match: Sendable {
        let url: URL
        let reading: SizeReading
        /// Set only where matches know what they belong to, which today means the
        /// bundle identifier behind a set of leftovers.
        var owner: String?
        var ownerName: String?
    }

    private func gatherMatches(continuation: AsyncStream<ScanEvent>.Continuation) -> [Match] {
        var candidates: [URL] = []
        var owners: [String: (identifier: String, name: String)] = [:]

        switch definition.match {
        case .wholeRoot:
            candidates = [root]

        case .immediateChildren:
            candidates = directories(in: root)

        case .namedChildren(let names):
            candidates = directories(in: root).filter { names.contains($0.lastPathComponent) }

        case .childrenWithPrefix(let prefixes):
            candidates = directories(in: root).filter { child in
                prefixes.contains { child.lastPathComponent.hasPrefix($0) }
            }

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

        case .downloadedCloudFiles:
            let keys: [URLResourceKey] = [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isRegularFileKey,
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else { return [] }

            for case let file as URL in enumerator {
                if Task.isCancelled { return [] }
                guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
                guard values.isRegularFile == true, values.isUbiquitousItem == true else { continue }
                // `.notDownloaded` items are placeholders that occupy nothing
                // locally, so there is no space to reclaim from them.
                let status = values.ubiquitousItemDownloadingStatus
                guard status == .current || status == .downloaded else { continue }
                candidates.append(file)
            }

        case .orphanedSupport(let scope):
            let kind: Orphan.Kind = scope == .application ? .application : .tool
            for orphan in OrphanStore.standard().orphans(kind: kind) {
                if Task.isCancelled { return [] }
                let name = OrphanStore.readableName(for: orphan.identifier)
                for path in orphan.paths {
                    candidates.append(path)
                    owners[path.path] = (orphan.identifier, name)
                }
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
            // A match whose contents could not be read measures as nothing.
            // Dropping it here would make unreadable content disappear from the
            // scan without a trace, which is the one thing a size must not do.
            guard reading.allocatedSize > 0 || reading.fileCount > 0 || reading.encounteredDenial
            else { continue }
            let owner = owners[candidate.path]
            matches.append(
                Match(
                    url: candidate,
                    reading: reading,
                    owner: owner?.identifier,
                    ownerName: owner?.name
                )
            )
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
            case .bundleIdentifierNames:
                // Owned by the rules that match by identifier. Without this a
                // folder sweep and an orphan rule would both claim the same
                // bytes, and the total would count them twice.
                var name = url.lastPathComponent
                if name.hasSuffix(".plist") { name = String(name.dropLast(6)) }
                if BundleIdentifier.isWellFormed(name) { return true }
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
            status: definition.status,
            wasPartlyUnreadable: reading.encounteredDenial,
            holdsAuthoredWork: definition.holdsAuthoredWork
        )
    }

    /// One finding for everything an uninstalled app left behind, across every
    /// folder it wrote to.
    private func makeOwnerFinding(from matches: [Match], owner: String) -> Finding? {
        let reading = matches.map(\.reading).reduce(SizeReading(), +)
        guard reading.allocatedSize > 0, let first = matches.first else { return nil }

        let places = matches.count == 1 ? "1 place" : "\(matches.count) places"
        return Finding(
            id: "\(definition.id).\(owner)",
            ruleID: definition.id,
            category: definition.category,
            displayName: first.ownerName ?? owner,
            // The identifier goes in the subtitle: the app is not here to ask
            // for its real name, so a guessed one is never the only evidence.
            subtitle: "\(owner) · left behind in \(places)",
            paths: matches.map(\.url),
            fileCount: reading.fileCount,
            allocatedSize: reading.allocatedSize,
            lastUsed: reading.newestModification,
            grade: definition.grade,
            action: definition.action,
            privilege: definition.privilege,
            explanation: definition.explanation,
            status: definition.status,
            wasPartlyUnreadable: reading.encounteredDenial,
            holdsAuthoredWork: definition.holdsAuthoredWork
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
            status: definition.status,
            wasPartlyUnreadable: match.reading.encounteredDenial,
            holdsAuthoredWork: definition.holdsAuthoredWork
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
        case .lastModified, .lastUsed:
            guard let modified = reading.newestModification else { return "no recorded activity" }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            let verb = definition.subtitleStyle == .lastUsed ? "last used" : "last built"
            return "\(verb) \(relative.localizedString(for: modified, relativeTo: Date()))"

        case .fileCount:
            let files = reading.fileCount
            return files == 1 ? "1 file" : "\(files.formatted(.number)) files"

        case .supersededBuild:
            return "an older version · your newest one is kept"
        }
    }
}
