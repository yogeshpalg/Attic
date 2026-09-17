import Foundation

/// How much Attic has moved to the Trash over its lifetime.
///
/// Deliberately "moved to the Trash" rather than "freed": emptying the Trash is
/// the user's act, not Attic's, and a counter that claimed credit for space the
/// user has not actually released yet would be the same kind of lie as a total
/// that counts bytes nothing would remove.
///
/// Stored in preferences rather than derived, because it has to survive the app
/// quitting — and injectable, so tests never touch the real defaults.
struct ReclaimedTally: Sendable, Equatable {

    private enum Key {
        static let bytes = "attic.reclaimed.bytes"
        static let items = "attic.reclaimed.items"
        static let since = "attic.reclaimed.since"
    }

    // UserDefaults is documented as thread-safe but is not marked Sendable, so
    // the compiler needs telling. Without this it is a warning today and an
    // error under the Swift 6 language mode.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Bytes moved to the Trash since the counter was last reset.
    var bytes: Int64 {
        Int64(defaults.integer(forKey: Key.bytes))
    }

    var items: Int {
        defaults.integer(forKey: Key.items)
    }

    /// When counting started. `nil` until the first removal, so a fresh install
    /// shows nothing rather than "0 bytes since today".
    var since: Date? {
        defaults.object(forKey: Key.since) as? Date
    }

    var hasRecordedAnything: Bool { bytes > 0 || items > 0 }

    /// Adds a removal to the record. `now` is passed in rather than read, so the
    /// first-removal date is testable.
    func add(bytes newBytes: Int64, items newItems: Int, now: Date = Date()) {
        guard newBytes > 0 || newItems > 0 else { return }

        // Saturating rather than wrapping: a counter that went negative after a
        // few exabytes would be a worse answer than a stuck one.
        let total = bytes.addingReportingOverflow(newBytes)
        defaults.set(Int(total.overflow ? Int64.max : total.partialValue), forKey: Key.bytes)
        defaults.set(items + newItems, forKey: Key.items)

        if since == nil {
            defaults.set(now, forKey: Key.since)
        }
    }

    func reset() {
        defaults.removeObject(forKey: Key.bytes)
        defaults.removeObject(forKey: Key.items)
        defaults.removeObject(forKey: Key.since)
    }
}
