import Foundation

/// Whether this process can read the whole disk — asked directly, rather than
/// inferred from a scan that came back short.
///
/// Attic used to find out the expensive way: scan, notice a rule hit `EPERM`,
/// and mark every figure on screen as a floor. That is accurate but it is late.
/// The first thing the app can honestly say about its own numbers arrived after
/// the scan, and "at least 4 GB" is a poor way to learn you needed to grant
/// something. Asking up front costs one `open(2)`.
enum FullDiskAccess {

    enum State: Sendable, Equatable {
        /// The probe opened a file that only Full Disk Access can open.
        case granted
        /// The probe was refused. Every figure the app produces is a floor, and
        /// whole rules will report nothing rather than nothing being there.
        case denied
        /// The probe could not decide: the file it reads was not there at all.
        /// Treated as no news rather than bad news — claiming a permission
        /// problem that may not exist sends somebody into System Settings for
        /// nothing, which is the same class of lie as a wrong size.
        case undetermined
    }

    /// The system TCC database. Read-protected on every release Attic supports,
    /// present on a stock install, and — the part that matters — it cannot
    /// raise a prompt: the open either succeeds or fails with `EPERM`. So the
    /// probe is silent, which a permission check has to be. Nothing is read out
    /// of it; the open *is* the test and the descriptor closes immediately.
    ///
    /// `Denylist` names this same directory as protected. Consistent, not
    /// contradictory: Attic opens it to ask a question about itself and will
    /// never offer it as something to remove.
    static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// `open(2)` rather than `FileManager.fileExists` so the refusal can be told
    /// apart from the absence.
    ///
    /// `fileExists` collapses both into `false`, and the two mean opposite
    /// things: refused is "warn the user", missing is "say nothing". Reading
    /// `errno` is the only way to know which happened.
    static func state(probing path: String = probePath) -> State {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        switch errno {
        case EPERM, EACCES: return .denied
        default: return .undetermined
        }
    }

    /// The Full Disk Access list in System Settings.
    ///
    /// `com.apple.preference.security` is the old System Preferences name and
    /// survives only as a compatibility shim; System Settings on macOS 26 and 27
    /// publishes `com.apple.settings.PrivacySecurity.extension`, which is what
    /// was read out of the binary on this Mac. The failure mode of a stale
    /// identifier is the reason this is stated rather than assumed: it does not
    /// error, it opens System Settings at the top level and leaves somebody
    /// hunting through the sidebar — exactly the bug the Siri pane link had
    /// before its identifier was checked the same way.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )

    /// Why a grant needs a relaunch, in the app's own words.
    ///
    /// macOS hands a process its file-access rights when it launches, so ticking
    /// Attic in System Settings does nothing for the copy already running. This
    /// is the step every guide forgets and the reason somebody grants the
    /// permission, sees the same floors, and concludes the app is broken.
    static let relaunchNotice = """
        Granting it does not affect Attic until it restarts — macOS decides what \
        an app can read when the app launches.
        """
}
