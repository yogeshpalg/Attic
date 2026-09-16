import Foundation

struct SizeReading: Sendable, Equatable {
    var allocatedSize: Int64 = 0
    var fileCount: Int = 0
    var newestModification: Date?
    /// Set when the walk could not read part of the tree, which is how a
    /// permission problem reaches the UI instead of silently understating a total.
    var encounteredDenial = false

    static func + (lhs: SizeReading, rhs: SizeReading) -> SizeReading {
        SizeReading(
            allocatedSize: lhs.allocatedSize + rhs.allocatedSize,
            fileCount: lhs.fileCount + rhs.fileCount,
            newestModification: [lhs.newestModification, rhs.newestModification].compactMap(\.self).max(),
            encounteredDenial: lhs.encounteredDenial || rhs.encounteredDenial
        )
    }
}

/// Read-only size measurement.
///
/// Sums `totalFileAllocatedSize` rather than logical file size so figures track
/// `du` rather than Finder's "size on disk". Note that this also means APFS clones
/// are counted once per clone — two files sharing blocks each report their full
/// size — which is exactly why freed space can come out lower than the total
/// selected, and why that has to be said in the interface rather than hidden.
enum DiskMeasure {

    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .isRegularFileKey,
        .isDirectoryKey,
        .contentModificationDateKey,
    ]

    static func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> SizeReading {
        var reading = SizeReading()

        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = values?.isDirectory ?? false

        if !isDirectory {
            reading.allocatedSize = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            reading.fileCount = 1
            reading.newestModification = values?.contentModificationDate
            return reading
        }

        reading.newestModification = values?.contentModificationDate

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                reading.encounteredDenial = true
                return true
            }
        )

        guard let enumerator else {
            reading.encounteredDenial = true
            return reading
        }

        for case let child as URL in enumerator {
            if isCancelled() { return reading }
            guard let childValues = try? child.resourceValues(forKeys: Set(keys)) else {
                reading.encounteredDenial = true
                continue
            }
            let bytes = childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0
            reading.allocatedSize += Int64(bytes)
            if childValues.isRegularFile == true { reading.fileCount += 1 }
            if let modified = childValues.contentModificationDate {
                reading.newestModification = max(reading.newestModification ?? modified, modified)
            }
        }

        return reading
    }
}

/// Free-space accounting.
///
/// Reports the plain available capacity and the "important usage" figure
/// separately, because macOS counts purgeable space as available in the second
/// and not the first. The gap between them is most of the reason a cleanup can
/// look like it did nothing.
enum VolumeSpace {

    /// `df /` describes the read-only system snapshot and understates real usage.
    /// The user's data lives on the Data volume, so that is what gets measured.
    static let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")

    struct Reading: Sendable, Equatable {
        let available: Int64
        let availableForImportantUsage: Int64
        let total: Int64

        var purgeable: Int64 { max(0, availableForImportantUsage - available) }
    }

    static func read(_ url: URL = dataVolume) -> Reading? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return Reading(
            available: Int64(values.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? 0,
            total: Int64(values.volumeTotalCapacity ?? 0)
        )
    }
}
