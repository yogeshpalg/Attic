import Foundation

/// One local APFS snapshot.
///
/// These are the largest part of what macOS reports as "purgeable" on a Mac with
/// Time Machine enabled: hourly local snapshots of the Data volume, kept so you
/// can restore a file without the backup disk attached.
struct LocalSnapshot: Sendable, Equatable, Identifiable {

    enum Kind: Sendable, Equatable {
        /// An hourly local snapshot. Reclaimable, at the cost of local restore points.
        case timeMachine
        /// Taken before a system update so the update can be rolled back. Attic
        /// lists these for completeness and never offers them.
        case systemUpdate
        case other
    }

    let name: String
    let volume: URL
    let kind: Kind
    /// Parsed from the snapshot name. `nil` for names that carry no date, which
    /// is normal for system-update snapshots.
    let createdAt: Date?

    var id: String { "\(volume.path)#\(name)" }

    /// `com.apple.TimeMachine.2026-09-14-200806.local`
    private static let timeMachinePrefix = "com.apple.TimeMachine."
    private static let systemUpdatePrefix = "com.apple.os.update-"
    private static let localSuffix = ".local"

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // tmutil names snapshots in the machine's own time zone, so the date in
        // the name is read back the same way rather than as UTC.
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init(name: String, volume: URL) {
        self.name = name
        self.volume = volume

        if name.hasPrefix(Self.timeMachinePrefix) {
            kind = .timeMachine
        } else if name.hasPrefix(Self.systemUpdatePrefix) {
            kind = .systemUpdate
        } else {
            kind = .other
        }

        createdAt = Self.date(from: name)
    }

    static func date(from name: String) -> Date? {
        guard name.hasPrefix(timeMachinePrefix) else { return nil }
        var stamp = String(name.dropFirst(timeMachinePrefix.count))
        if stamp.hasSuffix(localSuffix) {
            stamp = String(stamp.dropLast(localSuffix.count))
        }
        return nameFormatter.date(from: stamp)
    }
}

/// Lists local APFS snapshots, read-only.
///
/// `fs_snapshot_list` is used rather than shelling out to `tmutil`: it needs no
/// elevated privileges to *list*, and it keeps the app free of subprocesses. The
/// header exposing it also declares create, delete, rename, mount and revert —
/// none of which anything in Attic calls.
enum SnapshotStore {

    static let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
    static let systemVolume = URL(fileURLWithPath: "/")

    static func list(on volume: URL = dataVolume) -> [LocalSnapshot] {
        let descriptor = open(volume.path, O_RDONLY)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        // Both are required: the call behaves like `getattrlistbulk`, which
        // refuses a request that does not ask which attributes came back.
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)

        // macOS keeps on the order of a day's worth of hourly snapshots, so this
        // is generous. A single call is made; the buffer is grown once if the
        // kernel says it was short.
        var capacity = 64 * 1024
        for _ in 0..<2 {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            defer { buffer.deallocate() }

            let count = fs_snapshot_list(descriptor, &attributes, buffer, capacity, 0)
            if count >= 0 {
                return parse(buffer: buffer, count: Int(count), volume: volume)
            }
            guard errno == ERANGE else { return [] }
            capacity *= 8
        }
        return []
    }

    /// Each entry is a length, the set of attributes returned, then the name as
    /// an `attrreference_t` pointing past itself.
    private static func parse(
        buffer: UnsafeMutableRawPointer, count: Int, volume: URL
    ) -> [LocalSnapshot] {
        var snapshots: [LocalSnapshot] = []
        var cursor = UnsafeRawPointer(buffer)

        for _ in 0..<count {
            let entryLength = cursor.loadUnaligned(as: UInt32.self)
            guard entryLength > 0 else { break }

            let field = cursor
                .advanced(by: MemoryLayout<UInt32>.size)
                .advanced(by: MemoryLayout<attribute_set_t>.size)
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let name = String(
                cString: field
                    .advanced(by: Int(reference.attr_dataoffset))
                    .assumingMemoryBound(to: CChar.self)
            )

            if !name.isEmpty {
                snapshots.append(LocalSnapshot(name: name, volume: volume))
            }
            cursor = cursor.advanced(by: Int(entryLength))
        }
        return snapshots
    }
}

/// What macOS is holding onto that Attic's rules cannot see.
///
/// The figure is reported as one number by the system and cannot be broken down
/// per snapshot: snapshots share storage with the live volume and with each
/// other, so no individual one has a size of its own, and removing one can free
/// anything between nothing and all of it. That is why these bytes are reported
/// separately and never added to what a scan "found" — a total that mixes
/// measured bytes with an unattributable estimate is a total that lies.
struct SystemSpaceReport: Sendable, Equatable {

    /// Space macOS counts as available-for-important-usage but not as free: the
    /// amount it will reclaim on its own when the disk fills up.
    let purgeable: Int64
    let snapshots: [LocalSnapshot]

    var timeMachineSnapshots: [LocalSnapshot] {
        snapshots.filter { $0.kind == .timeMachine }
    }

    /// Snapshots macOS took before installing an update, so the update can be
    /// rolled back.
    ///
    /// Reported rather than offered. Removing one needs root, which Attic does
    /// not ask for, and it is the only way back if an update went wrong — but
    /// leaving it invisible means an old update can hold gigabytes with nothing
    /// on screen to explain it.
    var systemUpdateSnapshots: [LocalSnapshot] {
        snapshots.filter { $0.kind == .systemUpdate }
    }

    /// True when there is something here worth telling the user about.
    var isWorthShowing: Bool {
        purgeable > 0 || !timeMachineSnapshots.isEmpty || !systemUpdateSnapshots.isEmpty
    }

    /// The command that removes an update's rollback point. Shown, never run:
    /// it needs root, and it is the only way back from a bad update.
    var discardUpdateSnapshotCommand: String {
        "sudo tmutil deletelocalsnapshots \(systemUpdateSnapshots.first?.name ?? "<snapshot>")"
    }

    var updateSnapshotExplanation: Explanation {
        Explanation(
            whatThisIs: """
                Before installing a macOS update, the system takes a snapshot of the \
                disk as it was. It is what "roll back this update" uses, and it is \
                kept until macOS decides it is no longer needed.
                """,
            whatStopsWorking: """
                You lose the ability to undo that macOS update. Nothing else changes, \
                and your files are not part of what is removed.
                """,
            doesItComeBack: """
                Not for that update. A new one is taken the next time macOS installs one.
                """
        )
    }

    var oldestSnapshot: Date? {
        timeMachineSnapshots.compactMap(\.createdAt).min()
    }

    var newestSnapshot: Date? {
        timeMachineSnapshots.compactMap(\.createdAt).max()
    }

    /// The exact operation that would reclaim this space, shown rather than run.
    /// `thinlocalsnapshots` asks macOS to free a target number of bytes at a
    /// given urgency, which is what Storage Settings does behind its own button.
    var reclaimCommand: String {
        "sudo tmutil thinlocalsnapshots \(SnapshotStore.dataVolume.path) \(purgeable) 4"
    }

    static func read() -> SystemSpaceReport {
        SystemSpaceReport(
            purgeable: VolumeSpace.read()?.purgeable ?? 0,
            snapshots: SnapshotStore.list()
        )
    }

    var explanation: Explanation {
        Explanation(
            whatThisIs: """
                macOS keeps hourly snapshots of your disk so you can recover a file \
                without your backup drive attached. It counts the space they use as \
                free, because it will delete them itself once you need the room.
                """,
            whatStopsWorking: """
                You lose the ability to restore a file from earlier today or \
                yesterday without your Time Machine disk. Backups already on an \
                external drive are untouched.
                """,
            doesItComeBack: """
                Yes. Time Machine takes a new local snapshot every hour, so the space \
                fills up again over the following day.
                """
        )
    }
}
