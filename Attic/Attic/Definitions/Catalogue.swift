import Foundation

/// Where definitions come from. The compiled catalogue is the fallback that ships
/// in every build; a signed bundle fetched from the public definitions repository
/// will be a second conformer, so adding it is a swap rather than a rewrite.
protocol DefinitionSource: Sendable {
    func load() throws -> [RuleDefinition]
}

struct CompiledDefinitions: DefinitionSource {
    func load() throws -> [RuleDefinition] { Catalogue.all }
}

/// Resolves the active catalogue and filters out anything this build is too old
/// to understand, so a newer rule reaching an older app is inert rather than wrong.
struct DefinitionStore: Sendable {
    let source: DefinitionSource
    let appVersion: String
    /// The macOS this Mac is running. A rule can be right for one release and
    /// wrong for the next, so the store answers "does this apply here" rather
    /// than handing every rule to the engine and hoping.
    let osVersion: String
    /// What this Mac is. Some locations exist on one architecture and not the
    /// other, and a rule that cannot be right here is better left out than
    /// reported as having found nothing.
    let architecture: SystemSupport.Architecture

    /// When on, rules that match authored work are demoted to detect-only:
    /// still found, still measured, still explained — but with no checkbox, so
    /// no sequence of clicks can remove them.
    ///
    /// On by default. The alternative is an app where one wrong tick costs
    /// somebody the conversation history behind five projects, and no amount of
    /// careful copy makes that an acceptable default.
    let protectsAuthoredWork: Bool

    init(
        // Compiled rules, official signed updates over them, the user's own
        // rules over those. With no signing key and no imported file — every
        // build today — this reads exactly like `CompiledDefinitions`.
        source: DefinitionSource = LayeredDefinitionSource(),
        appVersion: String = DefinitionStore.bundleVersion,
        osVersion: String = DefinitionStore.systemVersion,
        architecture: SystemSupport.Architecture = SystemSupport.currentArchitecture(),
        protectsAuthoredWork: Bool = true
    ) {
        self.source = source
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
        self.protectsAuthoredWork = protectsAuthoredWork
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    func definitions() -> [RuleDefinition] {
        let all = (try? source.load()) ?? Catalogue.all
        return all.filter(applies).map(protected)
    }

    /// Demotes a protected rule rather than hiding it. Hiding would leave the
    /// user wondering where their gigabyte went; detect-only shows the size and
    /// the explanation, and offers nothing.
    private func protected(_ rule: RuleDefinition) -> RuleDefinition {
        guard protectsAuthoredWork, rule.holdsAuthoredWork, rule.status == .active
        else { return rule }

        var demoted = rule
        demoted.status = .detectOnly
        return demoted
    }

    /// Both bounds are inclusive, and both are compared numerically so that
    /// 15.10 is newer than 15.9 rather than alphabetically older.
    func applies(_ rule: RuleDefinition) -> Bool {
        guard rule.minAppVersion.compare(appVersion, options: .numeric) != .orderedDescending
        else { return false }

        if let minimum = rule.minOSVersion,
           minimum.compare(osVersion, options: .numeric) == .orderedDescending {
            return false
        }
        if let maximum = rule.maxOSVersion,
           maximum.compare(osVersion, options: .numeric) == .orderedAscending {
            return false
        }
        if let required = rule.architecture, required != architecture.scope {
            return false
        }
        return true
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
            grade: .checkFirst,
            holdsAuthoredWork: true,
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
            holdsAuthoredWork: true,
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

    /// Space that is held locally but not owned locally. The only action here
    /// deletes nothing: the file stays in iCloud and comes back when opened,
    /// which is why it is graded `checkFirst` rather than `safe` — getting it
    /// back needs a network connection, and that is the user's call to make.
    static let cloud: [RuleDefinition] = [

        RuleDefinition(
            id: "icloud.downloaded-copies",
            minAppVersion: "1.0",
            category: .cloudStorage,
            displayName: "iCloud Drive files kept on this Mac",
            root: .home("Library/Mobile Documents/com~apple~CloudDocs"),
            match: .downloadedCloudFiles,
            // Anything still being edited locally, and the folders iCloud uses
            // for its own bookkeeping.
            exclude: [.pathComponent(".Trash"), .nameSuffix(".icloud")],
            grouping: .single,
            retention: .excludeModifiedWithin(days: 30),
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .evictCloudCopy,
            privilege: .user,
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Files that live in iCloud Drive and also keep a full copy on this Mac, so they open instantly and work offline.",
                whatStopsWorking: "Nothing while you are online — opening one downloads it again. Offline, the files you cleared will not be available until you reconnect.",
                doesItComeBack: "Yes. Nothing is deleted: the file stays in iCloud and downloads on demand."
            )
        ),
    ]

    /// Support files belonging to apps that are gone.
    ///
    /// Graded `checkFirst` without exception. Reinstalling an app whose support
    /// files were removed loses its settings and its local data, and Attic
    /// cannot tell a licence key from a cache. That grade also keeps these out
    /// of "Select safe items", so a bulk action can never sweep them up.
    static let apps: [RuleDefinition] = [

        RuleDefinition(
            id: "apps.orphaned-support-files",
            minAppVersion: "1.0",
            category: .removedApps,
            displayName: "Files left behind by apps you removed",
            // Every location the scanner looks in sits under ~/Library, so the
            // declared root still bounds the rule the way containment expects.
            root: .home("Library"),
            match: .orphanedSupport(.application),
            exclude: [],
            grouping: .perOwner,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Settings, caches and saved data belonging to apps that are no longer on this Mac. Dragging an app to the Trash leaves these behind.",
                whatStopsWorking: "Nothing you are using now. If you reinstall one of these apps it will start fresh, without its old settings or local data.",
                doesItComeBack: "No. If an app kept something here you still want — a licence key, a local database — take a copy before removing it."
            )
        ),

        RuleDefinition(
            id: "tools.orphaned-caches",
            minAppVersion: "1.0",
            category: .cachesAndLogs,
            displayName: "Caches from tools that are no longer installed",
            root: .home("Library"),
            match: .orphanedSupport(.tool),
            exclude: [],
            grouping: .perOwner,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            // Cheap to lose but expensive to rebuild: a package cache means
            // every dependency downloaded again the next time you build.
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Caches and logs written by command line tools and background helpers that no longer have an app on this Mac. A package manager's download cache is the usual example.",
                whatStopsWorking: "Nothing directly. If the tool is still installed as a command, its next run will be slower while it downloads or rebuilds what it kept here.",
                doesItComeBack: "Yes, the next time the tool needs it — over the network, if that is where it came from."
            )
        ),
    ]

    /// A cache that a named tool owns and will rebuild. One rule each, because
    /// "what stops working" is a different sentence for every one of them.
    private static func toolCache(
        id: String,
        name: String,
        root: PathSpec,
        grade: SafetyGrade = .safe,
        holdsAuthoredWork: Bool = false,
        whatThisIs: String,
        whatStopsWorking: String,
        doesItComeBack: String
    ) -> RuleDefinition {
        RuleDefinition(
            id: id,
            minAppVersion: "1.0",
            category: .cachesAndLogs,
            displayName: name,
            root: root,
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: grade,
            holdsAuthoredWork: holdsAuthoredWork,
            status: .active,
            explanation: Explanation(
                whatThisIs: whatThisIs,
                whatStopsWorking: whatStopsWorking,
                doesItComeBack: doesItComeBack
            )
        )
    }

    /// Caches, from the folder every app shares to the ones a single tool owns.
    static let caches: [RuleDefinition] = [

        RuleDefinition(
            id: "caches.user-library",
            minAppVersion: "1.0",
            category: .cachesAndLogs,
            displayName: "Cached files from apps and system services",
            root: .home("Library/Caches"),
            match: .immediateChildren,
            // Anything named after a bundle identifier belongs to the rules that
            // match by identifier. Nothing here is counted twice.
            exclude: [.bundleIdentifierNames],
            grouping: .perMatch,
            retention: .none,
            subtitleStyle: .lastUsed,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            // One rule covering every vendor that ever wrote here, so it is
            // never part of a bulk selection.
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Working files an app or a system service saved so it would not have to fetch or compute them twice. The folder they live in is the one macOS designates as expendable.",
                whatStopsWorking: "Nothing stops working. The app that owns a cache will be slower the next time you use it, while it rebuilds or downloads what it kept here.",
                doesItComeBack: "Yes, as each app needs it again."
            )
        ),

        RuleDefinition(
            id: "caches.xdg",
            minAppVersion: "1.0",
            category: .cachesAndLogs,
            displayName: "Caches from command line tools",
            root: .home(".cache"),
            match: .immediateChildren,
            exclude: [.bundleIdentifierNames],
            grouping: .perMatch,
            retention: .none,
            subtitleStyle: .lastUsed,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            // Some of what lands here is very expensive to fetch again — a
            // machine learning model cache can be gigabytes over a slow link.
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "The folder command line tools share for cached downloads and build output, following the convention most of them agree on.",
                whatStopsWorking: "Nothing directly, but the tool that owns one of these will fetch or rebuild its contents the next time it runs.",
                doesItComeBack: "Yes. Some of it is a large download, so check what is here before clearing it on a slow connection."
            )
        ),

        toolCache(
            id: "caches.npm",
            name: "npm's download cache",
            root: .home(".npm/_cacache"),
            whatThisIs: "Every package npm has downloaded, kept so installing the same version again does not need the network.",
            whatStopsWorking: "Nothing. The next install downloads what it needs again.",
            doesItComeBack: "Yes, as you install packages."
        ),

        toolCache(
            id: "caches.pip",
            name: "pip's download cache",
            root: .home("Library/Caches/pip"),
            whatThisIs: "Python packages pip has downloaded and built, kept so the same install does not need the network twice.",
            whatStopsWorking: "Nothing. The next install fetches and rebuilds what it needs.",
            doesItComeBack: "Yes, as you install packages."
        ),

        toolCache(
            id: "caches.node-gyp",
            name: "Node build headers",
            root: .home("Library/Caches/node-gyp"),
            whatThisIs: "Node header files kept so packages with native code can be compiled without downloading them again.",
            whatStopsWorking: "Nothing. The next native build downloads the headers it needs.",
            doesItComeBack: "Yes, per Node version, as you build."
        ),

        toolCache(
            id: "caches.go-build",
            name: "Go's build cache",
            root: .home("Library/Caches/go-build"),
            whatThisIs: "Compiled Go build output, kept so unchanged packages are not compiled twice.",
            whatStopsWorking: "Nothing. Your next build is slower because it compiles from scratch.",
            doesItComeBack: "Yes, as you build."
        ),

        toolCache(
            id: "caches.cargo-registry",
            name: "Rust's package registry",
            root: .home(".cargo/registry"),
            whatThisIs: "Crates that Cargo has downloaded and unpacked so builds can use them without the network.",
            whatStopsWorking: "Nothing. Your next build downloads the crates it needs again.",
            doesItComeBack: "Yes, as you build."
        ),

        toolCache(
            id: "caches.gradle",
            name: "Gradle's build cache",
            root: .home(".gradle/caches"),
            whatThisIs: "Dependencies and build output Gradle keeps between builds.",
            whatStopsWorking: "Nothing. Your next Gradle build downloads and recompiles what it needs.",
            doesItComeBack: "Yes, and it can be a large download on the first build afterwards."
        ),

        toolCache(
            id: "caches.maven",
            name: "Maven's local repository",
            root: .home(".m2/repository"),
            // Maven's local repository can hold artefacts that were installed
            // locally and exist nowhere else.
            grade: .checkFirst,
            holdsAuthoredWork: true,
            whatThisIs: "Every Java dependency Maven has downloaded, plus anything you have installed into your local repository yourself.",
            whatStopsWorking: "Published dependencies download again. Anything installed only locally, with no copy in a remote repository, is gone for good.",
            doesItComeBack: "Downloaded artefacts do. Locally installed ones do not."
        ),

        toolCache(
            id: "caches.pnpm",
            name: "pnpm's package store",
            root: .home("Library/pnpm/store"),
            whatThisIs: "The shared store pnpm links every project's packages from, so one copy serves them all.",
            whatStopsWorking: "Existing projects keep working; their links are rebuilt on the next install, which needs the network.",
            doesItComeBack: "Yes, as you install packages."
        ),

        toolCache(
            id: "caches.yarn",
            name: "Yarn's download cache",
            root: .home("Library/Caches/Yarn"),
            whatThisIs: "Packages Yarn has downloaded, kept so the same version installs without the network.",
            whatStopsWorking: "Nothing. The next install downloads again.",
            doesItComeBack: "Yes, as you install packages."
        ),

        toolCache(
            id: "caches.playwright",
            name: "Playwright's browsers",
            root: .home("Library/Caches/ms-playwright"),
            grade: .checkFirst,
            whatThisIs: "Full browser builds Playwright downloaded for running tests.",
            whatStopsWorking: "Your Playwright tests will not run until the browsers are downloaded again, which is several hundred megabytes.",
            doesItComeBack: "Yes, on the next test run, over the network."
        ),

        toolCache(
            id: "caches.simulator",
            name: "Simulator caches",
            root: .home("Library/Developer/CoreSimulator/Caches"),
            whatThisIs: "Working files the iOS Simulator keeps between runs, including downloaded runtime images.",
            whatStopsWorking: "Nothing. The Simulator rebuilds these the next time you run an app on it.",
            doesItComeBack: "Yes, on the next simulator launch."
        ),
    ]

    /// Leftovers from installing or updating macOS itself. Individually the
    /// largest things on this list: a full installer is twelve to fifteen
    /// gigabytes, and people forget they downloaded one.
    static let updates: [RuleDefinition] = [

        RuleDefinition(
            id: "updates.macos-installers",
            minAppVersion: "1.0",
            category: .installers,
            displayName: "Downloaded macOS installers",
            root: .absolute("/Applications"),
            // Matched by prefix, because the name carries the release and an
            // exact list would stop finding the next one.
            match: .childrenWithPrefix(["Install macOS", "Install OS X"]),
            exclude: [],
            grouping: .perMatch,
            retention: .none,
            subtitleStyle: .lastModified,
            applicability: .rootExists,
            action: .trash,
            privilege: .user,
            grade: .safe,
            status: .active,
            explanation: Explanation(
                whatThisIs: "A full macOS installer you downloaded to upgrade this Mac. Once the upgrade is done it has no further use, and it is one of the largest single files on most Macs.",
                whatStopsWorking: "Nothing. You would need to download it again to install that version of macOS on another Mac, or to reinstall it from scratch.",
                doesItComeBack: "Not on its own. Apple provides it again from the App Store or Software Update when you need it."
            )
        ),

        RuleDefinition(
            id: "updates.device-firmware",
            minAppVersion: "1.0",
            category: .installers,
            displayName: "Device software updates",
            // Rooted at the folder above, not at one device's folder: macOS
            // keeps a sibling directory per device kind — "iPhone Software
            // Updates", "iPad Software Updates", "Apple TV Software Updates" —
            // and a rule aimed at the iPhone one finds none of the others.
            // The match recurses, so one rule covers every device kind and any
            // new one Apple adds.
            root: .home("Library/iTunes"),
            match: .filesWithExtension("ipsw"),
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
                whatThisIs: "Firmware images this Mac downloaded to update or restore an iPhone, iPad or Apple TV. Each one is several gigabytes and only matches one device and one system version.",
                whatStopsWorking: "Nothing. The next restore downloads the firmware it needs.",
                doesItComeBack: "Yes, on demand, over the network."
            )
        ),

        RuleDefinition(
            id: "updates.install-data",
            minAppVersion: "1.0",
            category: .installers,
            displayName: "An interrupted macOS install",
            root: .absolute("/macOS Install Data"),
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .revealOnly,
            // Root owns this, and Attic does not escalate: it will point at it
            // rather than pretend it can remove it.
            privilege: .administrator,
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Files macOS staged for an update that has not finished. If an install was interrupted or abandoned, they can sit here for months.",
                whatStopsWorking: "A pending update would start its download again. If an update is in progress right now, leave this alone until it finishes.",
                doesItComeBack: "Yes, the next time macOS prepares that update."
            )
        ),

        RuleDefinition(
            id: "updates.software-update-downloads",
            minAppVersion: "1.0",
            category: .installers,
            displayName: "Downloaded system updates",
            root: .absolute("/Library/Updates"),
            match: .wholeRoot,
            exclude: [],
            grouping: .single,
            retention: .none,
            subtitleStyle: .fileCount,
            applicability: .rootExists,
            action: .revealOnly,
            privilege: .administrator,
            grade: .checkFirst,
            status: .active,
            explanation: Explanation(
                whatThisIs: "Update packages Software Update has downloaded but not yet installed, or has finished with.",
                whatStopsWorking: "A pending update downloads again before it can install.",
                doesItComeBack: "Yes, whenever Software Update needs it."
            )
        ),
    ]

    /// Everything Attic ships, in one list.
    static var all: [RuleDefinition] { xcode + cloud + apps + caches + updates }
}
