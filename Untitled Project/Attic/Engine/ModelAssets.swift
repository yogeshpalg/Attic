import Foundation

/// The on-device model assets: Apple Intelligence, Siri understanding, speech,
/// translation and the rest of the UAF asset families.
///
/// This is the largest thing on a modern Apple silicon Mac that no cleaner can
/// touch, and the reason "System Data" is bigger than people expect. It lives on
/// the read-only system volume under SIP, so removing it is not a matter of
/// asking for administrator rights — it cannot be done at all, and a tool that
/// claims otherwise is lying about where the space went.
///
/// So Attic measures it, explains it, and points at the one supported control:
/// the Apple Intelligence & Siri settings pane. Nothing here is ever selectable.
struct OnDeviceModelAssets: Sendable, Equatable {

    /// Where macOS stages system assets. The tree holds far more than models —
    /// only the UAF families below are counted, so the figure is about models
    /// rather than about every asset macOS has ever downloaded.
    static let root = URL(fileURLWithPath: "/System/Library/AssetsV2")

    /// `com_apple_MobileAsset_UAF_FM_GenerativeModels`,
    /// `…UAF_Siri_Understanding`, `…UAF_Speech_AutomaticSpeechRecognition` and
    /// siblings. UAF is Apple's Unified Asset Framework.
    static let familyPrefix = "com_apple_MobileAsset_UAF_"

    /// One asset family, so the row can say what the space is actually for
    /// instead of quoting a single opaque total.
    struct Family: Sendable, Equatable, Identifiable {
        let directoryName: String
        let bytes: Int64

        var id: String { directoryName }

        /// `com_apple_MobileAsset_UAF_Siri_Understanding` → "Siri Understanding".
        var readableName: String {
            directoryName
                .replacingOccurrences(of: OnDeviceModelAssets.familyPrefix, with: "")
                .replacingOccurrences(of: "_", with: " ")
        }
    }

    let families: [Family]

    var bytes: Int64 { families.reduce(0) { $0 + $1.bytes } }

    var isWorthShowing: Bool { bytes > 0 }

    /// The largest few, for a subtitle. The tail is a long list of small
    /// families that would bury the two or three that matter.
    var largestFamilies: [Family] {
        Array(families.sorted { $0.bytes > $1.bytes }.prefix(3))
    }

    /// `nil` on Intel, where none of this exists: Apple Intelligence requires
    /// Apple silicon, so an empty row on an Intel Mac would be an answer to a
    /// question nobody asked.
    static func read(
        architecture: SystemSupport.Architecture = SystemSupport.currentArchitecture()
    ) -> OnDeviceModelAssets? {
        guard architecture == .appleSilicon else { return nil }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }

        let families = contents
            .filter { $0.lastPathComponent.hasPrefix(familyPrefix) }
            .map { directory in
                Family(
                    directoryName: directory.lastPathComponent,
                    bytes: DiskMeasure.measure(directory).allocatedSize
                )
            }
            .filter { $0.bytes > 0 }

        guard !families.isEmpty else { return nil }
        return OnDeviceModelAssets(families: families)
    }

    /// The supported way to reduce this, and the only one.
    ///
    /// The identifier was read out of this Mac's own System Settings binary
    /// rather than taken from a published list — panes were reorganised in
    /// macOS 26 and again in 27, and a stale identifier silently opens System
    /// Settings at the top level instead of failing.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")

    var explanation: Explanation {
        Explanation(
            whatThisIs: """
                Models macOS downloaded to run Apple Intelligence, Siri, dictation \
                and translation on this Mac rather than on a server. They are \
                counted as part of the system, which is why they are hard to find \
                in Storage Settings.
                """,
            whatStopsWorking: """
                Nothing, because Attic cannot remove these and neither can any \
                other app — they sit on the read-only system volume that System \
                Integrity Protection covers. Turning Apple Intelligence off in \
                System Settings, or removing languages you do not use, is the only \
                supported way to reduce them.
                """,
            doesItComeBack: """
                Yes. macOS downloads whatever the features you have enabled need, \
                so the space returns unless the feature stays off.
                """
        )
    }
}
