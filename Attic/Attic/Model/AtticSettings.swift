import Foundation

/// The handful of choices that outlive a launch.
///
/// Defaults-backed and injectable for the same reason as `ReclaimedTally`:
/// tests must never write to the real preferences, and the app must never lose
/// a safety setting because it was only held in memory.
struct AtticSettings: Sendable {

    private enum Key {
        static let protectsAuthoredWork = "attic.protectsAuthoredWork"
    }

    // UserDefaults is documented as thread-safe but is not marked Sendable, so
    // the compiler needs telling. Without this it is a warning today and an
    // error under the Swift 6 language mode.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Registered rather than assigned, so "on" is the answer on a fresh
        // install without overwriting a choice somebody already made.
        defaults.register(defaults: [Key.protectsAuthoredWork: true])
    }

    /// Whether rules that match authored work are held back from being offered.
    ///
    /// On by default, and the default matters more than the switch: the first
    /// scan somebody runs is the one where they have not yet learned which of
    /// these rows is a cache and which is a year of conversation history.
    var protectsAuthoredWork: Bool {
        get { defaults.bool(forKey: Key.protectsAuthoredWork) }
        nonmutating set { defaults.set(newValue, forKey: Key.protectsAuthoredWork) }
    }
}
