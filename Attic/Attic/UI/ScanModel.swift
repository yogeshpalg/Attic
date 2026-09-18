import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class ScanModel {

    enum Phase: Equatable {
        case firstRun
        case scanning
        case review
    }

    struct Withheld: Identifiable {
        let id = UUID()
        let ruleID: String
        let count: Int
        let bytes: Int64
        let reason: WithheldReason
    }

    private(set) var phase: Phase = .firstRun
    private(set) var findings: [Finding] = []
    private(set) var unavailable: [(ruleID: String, reason: UnavailableReason)] = []
    /// What the rules deliberately left alone. Shown to the user, because
    /// "nothing found" and "withheld 1.15 GB on every scan" must not look alike.
    private(set) var withheld: [Withheld] = []
    /// Surfaced in the interface rather than logged. A non-empty list is a bug
    /// in a rule, and hiding it is how a destructive one would go unnoticed.
    private(set) var rejections: [(ruleID: String, path: String, reason: RejectionReason)] = []
    private(set) var spaceAtStart: VolumeSpace.Reading?
    /// Read again after a removal, so the interface can report what actually came
    /// back rather than assuming the selected total was freed. APFS clones and
    /// shared blocks mean the two figures differ, and the difference is the
    /// user's question, not a detail to hide.
    private(set) var spaceAfterRemoval: VolumeSpace.Reading?
    private(set) var activeRuleIDs: Set<String> = []
    /// Space macOS manages on its own — local snapshots, and the purgeable figure
    /// it reports as free. Kept apart from `findings` because it cannot be
    /// attributed per item, and shown anyway: a cleaner that can see 68 GB and
    /// says nothing about it sends the user to System Settings to finish the job.
    private(set) var systemSpace: SystemSpaceReport?
    /// The on-device model assets, on Apple silicon. Measured on a background
    /// task and assigned when it finishes, because it walks several gigabytes of
    /// system assets and the scan should not wait on a figure nothing can act on.
    private(set) var modelAssets: OnDeviceModelAssets?
    private var modelAssetsTask: Task<Void, Never>?

    /// What the user has ticked. Only ever holds ids of selectable findings, and
    /// starts empty on every scan: nothing is pre-selected, so removing anything
    /// takes a deliberate act.
    private(set) var selection: Set<String> = []
    /// The record of the last removal, kept so the interface can report what it
    /// did instead of claiming it worked.
    private(set) var receipt: RemovalReceipt?
    /// Mirrors the stored lifetime total so the interface updates the moment a
    /// removal lands — preferences are not observable on their own.
    private(set) var lifetimeReclaimed: Int64 = 0
    private(set) var lifetimeItems: Int = 0
    private(set) var lifetimeSince: Date?

    /// How the list is ordered. The default is not size: size tells you where
    /// the bytes are, staleness tells you which ones you will not miss.
    enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case stalestFirst
        case largestFirst
        case smallestFirst
        case mostFiles
        case name

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stalestFirst: "Unused longest"
            case .largestFirst: "Largest first"
            case .smallestFirst: "Smallest first"
            case .mostFiles: "Most files"
            case .name: "Name"
            }
        }
    }

    /// A floor on what is worth putting in front of someone. Forty rows of 4 KB
    /// leftovers bury the 217 MB one, and nobody reclaims a disk four kilobytes
    /// at a time. Whatever falls below it is counted and reported, never
    /// silently dropped.
    enum SizeFloor: Int64, CaseIterable, Identifiable, Sendable {
        case everything = 0
        case oneMegabyte = 1_048_576
        case fiveMegabytes = 5_242_880
        case twentyFiveMegabytes = 26_214_400
        case oneHundredMegabytes = 104_857_600

        var id: Int64 { rawValue }

        var title: String {
            switch self {
            case .everything: "Everything"
            case .oneMegabyte: "1 MB and up"
            case .fiveMegabytes: "5 MB and up"
            case .twentyFiveMegabytes: "25 MB and up"
            case .oneHundredMegabytes: "100 MB and up"
            }
        }
    }

    /// What the sidebar is pointing at. Space macOS manages is a destination of
    /// its own rather than a section in the list: it is the largest figure on
    /// most Macs, it belongs to no category, and nothing in it is on offer — so
    /// it neither belongs among the findings nor deserves to be buried.
    enum Destination: Hashable, Sendable {
        case everything
        case category(Category)
        case managedByMacOS
        /// The uninstaller proper: apps that are installed now, and what each
        /// one would take with it.
        case installedApps
    }

    var destination: Destination = .everything
    var sortOrder: SortOrder = .stalestFirst
    var sizeFloor: SizeFloor = .fiveMegabytes

    /// Whether authored work is held back from being offered. Changing it
    /// rescans, because it changes what the catalogue is allowed to offer.
    private(set) var protectsAuthoredWork: Bool = true

    func setProtectsAuthoredWork(_ isOn: Bool) {
        guard isOn != protectsAuthoredWork else { return }
        protectsAuthoredWork = isOn
        settings.protectsAuthoredWork = isOn
        if phase != .firstRun { startScan() }
    }

    /// The category in view, or `nil` for everywhere.
    var selectedCategory: Category? {
        if case .category(let category) = destination { category } else { nil }
    }

    private var scanTask: Task<Void, Never>?
    private let store: DefinitionStore
    /// The catalogue this scan ran, kept because the planner and the executor
    /// verify containment against the rule that produced a finding — never
    /// against anything the finding carries.
    private(set) var definitions: [RuleDefinition] = []
    /// Rule identifiers to their display names, resolved once per scan. The
    /// events that report on a rule rather than a finding carry only the id.
    private var ruleNames: [String: String] = [:]

    private let trash: @Sendable (URL) throws -> URL?
    /// The running total across every removal this app has ever done.
    let tally: ReclaimedTally
    private let appStore: InstalledAppStore
    private let settings: AtticSettings
    private let readDiskAccess: @Sendable () -> FullDiskAccess.State

    /// Whether macOS will let this process read the whole disk. Known before the
    /// first scan rather than deduced from one, so the app can say the figures
    /// are floors at the point somebody starts reading them.
    private(set) var diskAccess: FullDiskAccess.State = .undetermined

    /// The store is injected so a scan can be pointed at a known set of rules
    /// instead of the user's real home directory, the trash closure so that
    /// exercising removal does not put anything in the real Trash, the tally so
    /// tests never write to the real preferences, and the access probe so the
    /// denied case can be exercised on a machine that has the permission.
    init(
        store: DefinitionStore = DefinitionStore(),
        trash: @Sendable @escaping (URL) throws -> URL? = RemovalExecutor.moveToTrash,
        tally: ReclaimedTally = ReclaimedTally(),
        appStore: InstalledAppStore = .standard(),
        settings: AtticSettings = AtticSettings(),
        diskAccess: @Sendable @escaping () -> FullDiskAccess.State = { FullDiskAccess.state() }
    ) {
        self.store = store
        self.trash = trash
        self.tally = tally
        self.appStore = appStore
        self.settings = settings
        self.readDiskAccess = diskAccess
        protectsAuthoredWork = settings.protectsAuthoredWork
        lifetimeReclaimed = tally.bytes
        lifetimeItems = tally.items
        lifetimeSince = tally.since
        self.diskAccess = diskAccess()
    }

    /// Asked again when the app comes back to the front, which is when somebody
    /// returns from System Settings. The answer will not have changed for this
    /// process — rights are fixed at launch — but the app has to ask to know
    /// whether it is still the one telling the user to go and grant something.
    func refreshDiskAccess() {
        diskAccess = readDiskAccess()
    }

    /// Puts the lifetime figure back to nothing. The record is a convenience,
    /// not evidence, so clearing it costs nothing and needs no confirmation
    /// beyond the menu it sits in.
    func resetLifetimeTotal() {
        tally.reset()
        lifetimeReclaimed = 0
        lifetimeItems = 0
        lifetimeSince = nil
    }

    // MARK: - Derived

    var totalFound: Int64 { findings.reduce(0) { $0 + $1.allocatedSize } }

    var categoriesPresent: [Category] {
        Category.allCases.filter { category in
            findings.contains { $0.category == category }
        }
    }

    /// Everything found in a category, or everywhere when no category is given.
    /// Counted before the size floor is applied — the floor decides what is
    /// worth showing, never what was found.
    func total(in category: Category?) -> Int64 {
        allFindings(in: category).reduce(0) { $0 + $1.allocatedSize }
    }

    /// What Attic could actually act on, which is not the same figure as what it
    /// found: a detect-only or keep-graded finding is shown with its size and
    /// never offered. Presenting the two as one number would promise space the
    /// app has no intention of reclaiming.
    func selectableTotal(in category: Category?) -> Int64 {
        allFindings(in: category).filter(\.isSelectable).reduce(0) { $0 + $1.allocatedSize }
    }

    /// The user-facing name of a rule, for the banners that report on a whole
    /// rule rather than on a finding. Falls back to the identifier only if the
    /// rule is missing from the resolved catalogue, which would itself be a bug.
    func ruleName(_ ruleID: String) -> String {
        ruleNames[ruleID] ?? ruleID
    }

    // MARK: - Selection

    /// What is both ticked and on screen.
    ///
    /// Raising the size floor takes rows away, and a selection that outlived the
    /// row it belonged to would let the footer offer to remove something the
    /// list is not showing. The tick is remembered — lower the floor and it is
    /// still there — it just does not count while it cannot be seen.
    var selectedFindings: [Finding] {
        findings(in: nil).filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedFindings.reduce(0) { $0 + $1.allocatedSize }
    }

    func isSelected(_ finding: Finding) -> Bool { selection.contains(finding.id) }

    func toggle(_ finding: Finding) {
        // A finding the app will not act on cannot be ticked at all, so the
        // interface cannot offer a selection the planner would refuse.
        guard finding.isSelectable else { return }
        if selection.contains(finding.id) {
            selection.remove(finding.id)
        } else {
            selection.insert(finding.id)
        }
    }

    /// Everything in view that a bulk action is willing to touch: graded safe,
    /// and actually removable.
    ///
    /// `checkFirst` findings are left out deliberately — they are the ones that
    /// cost a rebuild or a download, and they are never part of a bulk action.
    func safeFindings(in category: Category?) -> [Finding] {
        findings(in: category).filter { $0.isSelectable && $0.grade == .safe }
    }

    /// True once every safe row in view is ticked, which is when the button that
    /// ticked them should offer to untick them again.
    func hasSelectedAllSafe(in category: Category?) -> Bool {
        let safe = safeFindings(in: category)
        return !safe.isEmpty && safe.allSatisfy { selection.contains($0.id) }
    }

    /// One button, both directions: ticks every safe row in view, or unticks
    /// them if they are already all ticked.
    ///
    /// Unticking removes exactly what this action would have added and nothing
    /// else, so a `checkFirst` row somebody ticked by hand survives — the button
    /// undoes its own work rather than clearing the list.
    func toggleSafeSelection(in category: Category?) {
        let safe = safeFindings(in: category)
        guard !safe.isEmpty else { return }

        if hasSelectedAllSafe(in: category) {
            for finding in safe {
                selection.remove(finding.id)
            }
        } else {
            for finding in safe {
                selection.insert(finding.id)
            }
        }
    }

    /// Kept for callers that only ever want the ticking half.
    func selectSafe(in category: Category?) {
        for finding in safeFindings(in: category) {
            selection.insert(finding.id)
        }
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: - Removal

    /// The dry run for what is currently ticked. The interface shows this before
    /// anything is touched.
    func plannedRemoval() -> RemovalPlan {
        RemovalPlan.plan(for: selectedFindings, definitions: definitions)
    }

    /// Moves the ticked findings to the Trash, then drops whatever left the disk
    /// from the list. Findings that were refused or failed stay, because they are
    /// still there.
    func removeSelected() {
        let chosen = selectedFindings
        guard !chosen.isEmpty else { return }

        let outcome = RemovalExecutor(definitions: definitions, trash: trash).execute(chosen)
        receipt = outcome

        guard !outcome.wasAbandoned else { return }

        // Only what actually moved. A refused or failed path contributes nothing
        // to the lifetime figure, the same way it contributes nothing to the
        // space that came back.
        tally.add(bytes: outcome.bytesTrashed, items: outcome.trashedCount)
        lifetimeReclaimed = tally.bytes
        lifetimeItems = tally.items
        lifetimeSince = tally.since

        let gone = Set(
            outcome.outcomes.compactMap { result -> String? in
                switch result {
                case .trashed(let path, _, _), .evicted(let path, _), .vanished(let path): path
                case .ran, .refused, .failed, .revealed: nil
                }
            }
        )
        findings.removeAll { finding in
            finding.paths.allSatisfy { gone.contains($0.path) }
        }
        selection = selection.filter { id in findings.contains { $0.id == id } }
        spaceAfterRemoval = VolumeSpace.read()
    }

    func dismissReceipt() {
        receipt = nil
    }

    // MARK: - Uninstaller

    /// Apps installed right now. Loaded on demand: it is a directory listing
    /// and a plist read per app, so there is no reason to do it during a scan.
    private(set) var installedApps: [InstalledApp] = []
    /// What the chosen app would take with it.
    private(set) var appFootprint: AppFootprint?
    private(set) var isLoadingApps = false

    func loadInstalledApps() {
        guard installedApps.isEmpty, !isLoadingApps else { return }
        isLoadingApps = true

        let store = appStore
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { store.apps() }.value
            guard let self else { return }
            installedApps = found
            isLoadingApps = false
        }
    }

    func chooseApp(_ app: InstalledApp?) {
        guard let app else {
            appFootprint = nil
            return
        }
        let store = appStore
        Task { [weak self] in
            let measured = await Task.detached(priority: .userInitiated) {
                store.footprint(for: app)
            }.value
            guard let self else { return }
            appFootprint = measured
        }
    }

    /// Quits the chosen app, so its files can be removed without leaving a
    /// running process with nothing underneath it.
    func quitChosenApp() {
        guard let identifier = appFootprint?.app.identifier else { return }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            running.terminate()
        }
        // Re-measure so the running flag, and the button that depends on it,
        // reflect what actually happened.
        chooseApp(appFootprint?.app)
    }

    /// Moves the chosen app and everything it wrote to the Trash, through the
    /// same planner and executor as every other removal — so the same three
    /// gates apply, and the same receipt comes back.
    func uninstallChosenApp() {
        guard let footprint = appFootprint, !footprint.isRunning else { return }

        let inputs = InstalledAppStore.removalPlanInputs(for: footprint)
        let outcome = RemovalExecutor(definitions: inputs.definitions, trash: trash)
            .execute(inputs.findings)
        receipt = outcome

        guard !outcome.wasAbandoned else { return }

        tally.add(bytes: outcome.bytesTrashed, items: outcome.trashedCount)
        lifetimeReclaimed = tally.bytes
        lifetimeItems = tally.items
        lifetimeSince = tally.since
        spaceAfterRemoval = VolumeSpace.read()

        // The app is gone, so it leaves both lists.
        installedApps.removeAll { $0.identifier == footprint.app.identifier }
        appFootprint = nil
    }

    /// Seeds the list without scanning, for previews and for tests that are
    /// about what the list does with findings rather than how it got them.
    func adopt(_ seeded: [Finding], definitions seededRules: [RuleDefinition] = []) {
        findings = seeded
        definitions = seededRules
        ruleNames = Dictionary(
            seededRules.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        selection = []
        receipt = nil
        phase = .review
    }

    /// Everything in scope, whatever its size. The figures are built from this.
    func allFindings(in category: Category?) -> [Finding] {
        category.map { c in findings.filter { $0.category == c } } ?? findings
    }

    /// What the list shows: in scope, above the floor, in the chosen order.
    func findings(in category: Category?) -> [Finding] {
        allFindings(in: category)
            .filter { $0.allocatedSize >= sizeFloor.rawValue }
            .sorted(by: isOrderedBefore)
    }

    private func isOrderedBefore(_ lhs: Finding, _ rhs: Finding) -> Bool {
        switch sortOrder {
        case .stalestFirst:
            // Staleness before size: size tells you where the bytes are,
            // staleness tells you which ones you will not miss.
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?) where l != r: return l < r
            default: return lhs.allocatedSize > rhs.allocatedSize
            }
        case .largestFirst:
            return lhs.allocatedSize == rhs.allocatedSize
                ? lhs.displayName < rhs.displayName
                : lhs.allocatedSize > rhs.allocatedSize
        case .smallestFirst:
            return lhs.allocatedSize == rhs.allocatedSize
                ? lhs.displayName < rhs.displayName
                : lhs.allocatedSize < rhs.allocatedSize
        case .mostFiles:
            return lhs.fileCount == rhs.fileCount
                ? lhs.allocatedSize > rhs.allocatedSize
                : lhs.fileCount > rhs.fileCount
        case .name:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// True when any figure on screen is a floor rather than a total, because
    /// part of what a rule measured could not be read. Full Disk Access is the
    /// usual reason, and the interface says so rather than showing a number
    /// that is quietly too small.
    var someSizesAreUnderstated: Bool {
        diskAccess == .denied
            || findings.contains { $0.wasPartlyUnreadable }
            || unavailable.contains { $0.reason == .permissionDenied }
    }

    /// Rules that found nothing, and why. Collapsed into one line by reason:
    /// with a catalogue covering tools most Macs do not have, listing every
    /// absent one would bury the two that matter.
    var unavailableSummary: [(reason: UnavailableReason, ruleNames: [String])] {
        Dictionary(grouping: unavailable, by: \.reason)
            .map { (reason: $0.key, ruleNames: $0.value.map { ruleName($0.ruleID) }.sorted()) }
            .sorted { $0.ruleNames.count > $1.ruleNames.count }
    }

    /// What the floor is keeping off screen. Reported rather than dropped: a
    /// hidden row and a row that was never found must not look the same.
    func hiddenByFloor(in category: Category?) -> (count: Int, bytes: Int64) {
        let hidden = allFindings(in: category).filter { $0.allocatedSize < sizeFloor.rawValue }
        return (hidden.count, hidden.reduce(0) { $0 + $1.allocatedSize })
    }

    // MARK: - Actions

    func startScan() {
        scanTask?.cancel()
        findings = []
        unavailable = []
        withheld = []
        rejections = []
        activeRuleIDs = []
        // A fresh scan starts with nothing ticked and no stale receipt on screen.
        selection = []
        receipt = nil
        spaceAfterRemoval = nil
        spaceAtStart = VolumeSpace.read()
        // Two stats and a snapshot listing, so this costs nothing next to the walks.
        systemSpace = SystemSpaceReport.read()
        phase = .scanning
        measureModelAssets()

        // Rebuilt per scan so the protection setting is applied to the rules
        // rather than to the findings after the fact — nothing downstream ever
        // sees an offer it should not have had.
        definitions = DefinitionStore(
            source: store.source,
            appVersion: store.appVersion,
            osVersion: store.osVersion,
            architecture: store.architecture,
            protectsAuthoredWork: protectsAuthoredWork
        ).definitions()
        ruleNames = Dictionary(
            definitions.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let engine = ScanEngine(definitions: definitions)

        scanTask = Task { [weak self] in
            for await event in engine.run() {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
            guard let self, !Task.isCancelled else { return }
            self.phase = .review
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        modelAssetsTask?.cancel()
        modelAssetsTask = nil
        phase = findings.isEmpty ? .firstRun : .review
    }

    /// Measured off the main actor. Nothing can act on this figure, so it
    /// arrives when it arrives rather than holding up the findings.
    private func measureModelAssets() {
        modelAssets = nil
        modelAssetsTask?.cancel()
        modelAssetsTask = Task { [weak self] in
            let architecture = self?.store.architecture ?? SystemSupport.currentArchitecture()
            let measured = await Task.detached(priority: .utility) {
                OnDeviceModelAssets.read(architecture: architecture)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.modelAssets = measured
        }
    }

    private func apply(_ event: ScanEvent) {
        switch event {
        case .began(let ruleID):
            activeRuleIDs.insert(ruleID)
        case .completed(let ruleID):
            activeRuleIDs.remove(ruleID)
        case .found(let finding):
            findings.append(finding)
        case .withheld(let ruleID, let count, let bytes, let reason):
            withheld.append(Withheld(ruleID: ruleID, count: count, bytes: bytes, reason: reason))
        case .unavailable(let ruleID, let reason):
            unavailable.append((ruleID, reason))
        case .rejected(let ruleID, let path, let reason):
            rejections.append((ruleID, path, reason))
        }
    }

    // MARK: - Verification

    /// Builds a `du` command covering every path found, so the reported figures
    /// can be checked against the system's own accounting. This is how stage one
    /// gets verified; nothing in the app shells out.
    func verificationCommand(for category: Category?) -> String {
        let paths = findings(in: category)
            .flatMap(\.paths)
            .map { "'\($0.path)'" }
        guard !paths.isEmpty else { return "" }
        return "du -sch \\\n  " + paths.joined(separator: " \\\n  ")
    }
}
