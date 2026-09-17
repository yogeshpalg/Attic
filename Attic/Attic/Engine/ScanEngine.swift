import Foundation

/// Runs the catalogue and streams events as they arrive.
///
/// Concurrency is bounded rather than unlimited. Twenty directory walks against
/// one APFS volume are metadata-bound, not CPU-bound, so beyond a handful they
/// contend instead of parallelising — and they make progress reporting and
/// cancellation worse. Cheap rules are ordered first so the list starts filling
/// immediately.
struct ScanEngine: Sendable {

    let definitions: [RuleDefinition]

    private var concurrencyLimit: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    func run() -> AsyncStream<ScanEvent> {
        let ordered = orderedForPerceivedSpeed(definitions)
        let limit = concurrencyLimit

        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            // Detached so the walks never land on the main actor, whatever the
            // caller's isolation happens to be.
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    var iterator = ordered.makeIterator()

                    for _ in 0..<limit {
                        guard let definition = iterator.next() else { break }
                        group.addTask { RuleScanner(definition: definition).scan(into: continuation) }
                    }

                    while await group.next() != nil {
                        if Task.isCancelled { break }
                        guard let definition = iterator.next() else { continue }
                        group.addTask { RuleScanner(definition: definition).scan(into: continuation) }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `wholeRoot` rules are a single stat-and-walk and usually return in well
    /// under a second; the recursive file matches are the slow ones.
    private func orderedForPerceivedSpeed(_ definitions: [RuleDefinition]) -> [RuleDefinition] {
        definitions.sorted { lhs, rhs in
            cost(lhs) < cost(rhs)
        }
    }

    private func cost(_ definition: RuleDefinition) -> Int {
        switch definition.match {
        case .wholeRoot: 0
        case .namedChildren: 1
        case .childrenWithPrefix: 1
        case .immediateChildren: 1
        case .filesWithExtension: 2
        // A recursive walk that also reads two cloud resource values per file.
        case .downloadedCloudFiles: 3
        // Ten shallow listings, then a LaunchServices lookup per candidate.
        case .orphanedSupport: 2
        }
    }
}
