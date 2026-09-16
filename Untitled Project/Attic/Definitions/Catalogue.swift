import Foundation

/// Where definitions come from. The compiled catalogue is the fallback that ships
/// in every build; a signed bundle fetched from the public definitions repository
/// will be a second conformer, so adding it is a swap rather than a rewrite.
protocol DefinitionSource: Sendable {
    func load() throws -> [RuleDefinition]
}

struct CompiledDefinitions: DefinitionSource {
    func load() throws -> [RuleDefinition] { Catalogue.xcode }
}

/// Resolves the active catalogue and filters out anything this build is too old
/// to understand, so a newer rule reaching an older app is inert rather than wrong.
struct DefinitionStore: Sendable {
    let source: DefinitionSource
    let appVersion: String

    init(source: DefinitionSource = CompiledDefinitions(), appVersion: String = DefinitionStore.bundleVersion) {
        self.source = source
        self.appVersion = appVersion
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func definitions() -> [RuleDefinition] {
        let all = (try? source.load()) ?? Catalogue.xcode
        return all.filter { rule in
            rule.minAppVersion.compare(appVersion, options: .numeric) != .orderedDescending
        }
    }
}

enum Catalogue {

    /// Shared caches that live inside DerivedData alongside the per-project
    /// folders. They are written on every build, so they can never satisfy a
    /// staleness rule and must be described separately or they stay invisible.
    static let derivedDataSharedCaches = [
        "ModuleCache.noindex",
        "SDKExplicitPrecompiledModules",
        "SDKStatCaches.noindex",
        "SymbolCache.noindex",
        "CompilationCache.noindex",
    ]

    static let xcode: [RuleDefinition] = [

        RuleDefinition(
            id: "xcode.derived-data.projects",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Build files for projects you are not working on",
            root: .home("Library/Developer/Xcode/DerivedData"),
            match: .immediateChildren,
            exclude: [
                .nameSuffix(".noindex"),
                .pathComponent("SDKExplicitPrecompiledModules"),
            ],
            grouping: .perMatch,
            retention: .excludeModifiedWithin(days: 7),
            subtitleStyle: .lastModified,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Xcode keeps the half-finished pieces of every build here, one folder per project, and never clears out the projects you have stopped working on.",
                whatStopsWorking: "Nothing. The next build of that project takes longer because it starts from scratch, and Xcode has to fetch its packages again.",
                doesItComeBack: "Yes, automatically, the next time you build."
            )
        ),

        RuleDefinition(
            id: "xcode.derived-data.shared-caches",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Xcode's shared build cache",
            root: .home("Library/Developer/Xcode/DerivedData"),
            match: .namedChildren(derivedDataSharedCaches),
            exclude: [],
            grouping: .single,
            // No staleness rule here on purpose: these are touched on every build,
            // so any recency test would withhold them forever.
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Precompiled pieces of Apple's own frameworks that Xcode shares between all of your projects, so it does not have to process them again for each one.",
                whatStopsWorking: "Nothing. Your first build afterwards is noticeably slower for every project, because all of this gets rebuilt once.",
                doesItComeBack: "Yes, automatically, as you build."
            )
        ),

        RuleDefinition(
            id: "xcode.device-support.ios",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Debug files for iPhone versions you no longer use",
            root: .home("Library/Developer/Xcode/iOS DeviceSupport"),
            match: .immediateChildren,
            exclude: [],
            grouping: .perMatch,
            retention: .keepNewestPerLeadingComponent,
            subtitleStyle: .supersededBuild,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Every time you plug in a phone running a version of iOS that Xcode has not seen before, it copies several gigabytes of debugging files from it and keeps them forever.",
                whatStopsWorking: "Nothing. The newest set for each device is always kept, so debugging carries on as normal.",
                doesItComeBack: "Yes, automatically, if you connect a device on that version again."
            )
        ),

        RuleDefinition(
            id: "xcode.previews",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "SwiftUI preview simulators",
            root: .home("Library/Developer/Xcode/UserData/Previews"),
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            // Deleting these as files breaks Previews. The sanctioned command is
            // the only correct removal path, which is why it is not `.trash`.
            action: .command(.simctlDeletePreviews),
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Hidden simulators Xcode builds so it can draw the live preview beside your code. They grow without limit and are never tidied up.",
                whatStopsWorking: "Nothing, but close Xcode first. Attic asks Xcode's own tool to clear these rather than deleting the files, because deleting them by hand stops Previews working until Xcode is reinstalled.",
                doesItComeBack: "Yes. The first preview you open afterwards takes a little longer while it rebuilds."
            )
        ),

        RuleDefinition(
            id: "xcode.coding-assistant.transcripts",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Coding assistant conversation history",
            root: .home("Library/Developer/Xcode/CodingAssistant"),
            match: .filesWithExtension("jsonl"),
            // The transcripts sit inside the provider's config directory, so the
            // exclusion has to be the `memory` folders and authored notes — not
            // the config directory itself, which would match nothing at all.
            exclude: [.pathComponent("memory"), .fileExtension("md")],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Xcode saves a full record of every conversation you have with its coding assistant. Nothing ever clears them out.",
                whatStopsWorking: "You lose the ability to scroll back through old sessions. Your settings, your instruction files and anything the assistant was told to remember are all kept.",
                doesItComeBack: "No, but your next session starts fresh, which is what most people want anyway."
            )
        ),

        RuleDefinition(
            id: "xcode.coding-assistant.snapshots",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Coding assistant edit checkpoints",
            root: .home("Library/Developer/Xcode/UserData/CodingAssistant"),
            match: .filesWithExtension("plist"),
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            // Losing these loses the ability to revert individual assistant edits.
            // That is a real cost, so it is not `safe` however well it regenerates.
            grade: .checkFirst,
            // Newly drafted rules ship detect-only and are promoted in a later
            // release after real-world exposure.
            status: .detectOnly,
            explanation: Explanation(
                whatThisIs: "Before the coding assistant changes a file, it saves a copy so the edit can be undone. These copies are kept indefinitely, one per edit, and on a busy machine they outgrow the conversations themselves.",
                whatStopsWorking: "You lose the ability to undo assistant edits from earlier sessions. If your work is committed to version control you already have a better record of the same thing.",
                doesItComeBack: "New checkpoints are saved as you keep working, but the old ones are gone."
            )
        ),

        RuleDefinition(
            id: "xcode.documentation-cache",
            minAppVersion: "1.0",
            category: .developerXcode,
            displayName: "Downloaded developer documentation",
            root: .home("Library/Developer/Xcode/DocumentationCache"),
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Apple's developer documentation, downloaded so Xcode can show it without a network connection.",
                whatStopsWorking: "Nothing while you are online. Documentation you look up will be fetched again as you need it.",
                doesItComeBack: "Yes, on demand."
            )
        ),
    ]
}
