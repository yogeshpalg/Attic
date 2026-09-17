import Testing
import Foundation
@testable import Attic

/// Invariant 23. A cache is safe because the tool rebuilds it. Conversation
/// history with a coding assistant is not a cache — nothing regenerates it, and
/// losing it costs the context behind however many projects it covered.
///
/// This suite exists because the transcripts rule shipped graded `.safe`, which
/// meant "Select safe items" would have ticked it. Someone nearly lost a year of
/// history across five projects to one click. The grade was wrong, and a grade
/// alone was never going to be enough.
@Suite("Protecting authored work")
struct ProtectionTests {

    private func rule(
        _ id: String, holdsAuthoredWork: Bool, grade: SafetyGrade = .checkFirst
    ) -> RuleDefinition {
        var definition = RuleDefinition.fixture(
            id: id, root: URL(fileURLWithPath: "/private/tmp"), grade: grade
        )
        definition.holdsAuthoredWork = holdsAuthoredWork
        return definition
    }

    @Test("Protection is on unless somebody turns it off")
    func protectionIsOnByDefault() {
        // The first scan somebody runs is the one where they have not yet
        // learned which row is a cache and which is a year of history.
        #expect(DefinitionStore().protectsAuthoredWork)
    }

    @Test("A rule that holds authored work is not offered while protection is on")
    func authoredWorkIsNotOffered() {
        let store = DefinitionStore(
            source: StubRules(rules: [
                rule("assistant.transcripts", holdsAuthoredWork: true),
                rule("caches.npm", holdsAuthoredWork: false),
            ]),
            protectsAuthoredWork: true
        )

        let resolved = store.definitions()
        let transcripts = resolved.first { $0.id == "assistant.transcripts" }
        let npm = resolved.first { $0.id == "caches.npm" }

        #expect(transcripts?.status == .detectOnly)
        #expect(npm?.status == .active)
    }

    @Test("It is shown, not hidden")
    func protectedRulesAreStillReported() {
        let store = DefinitionStore(
            source: StubRules(rules: [rule("assistant.transcripts", holdsAuthoredWork: true)]),
            protectsAuthoredWork: true
        )

        // Hiding it would leave someone hunting for a missing gigabyte. It is
        // measured and explained, and simply has no checkbox.
        #expect(store.definitions().count == 1)
    }

    @Test("Turning protection off offers it again")
    func protectionCanBeTurnedOff() {
        let store = DefinitionStore(
            source: StubRules(rules: [rule("assistant.transcripts", holdsAuthoredWork: true)]),
            protectsAuthoredWork: false
        )

        #expect(store.definitions().first?.status == .active)
    }

    @Test("A rule that was already detect-only is left alone")
    func alreadyDetectOnlyIsUnchanged() {
        var definition = rule("assistant.snapshots", holdsAuthoredWork: true)
        definition.status = .detectOnly

        let store = DefinitionStore(
            source: StubRules(rules: [definition]), protectsAuthoredWork: true
        )

        #expect(store.definitions().first?.status == .detectOnly)
    }

    @Test("Protected findings cannot be selected, planned or removed")
    func protectedFindingsAreInertEndToEnd() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        try tree.file("history/session.jsonl", bytes: 100_000)

        var definition = RuleDefinition.fixture(
            root: tree.root, match: .wholeRoot, grouping: .single, grade: .checkFirst
        )
        definition.holdsAuthoredWork = true

        let store = DefinitionStore(
            source: StubRules(rules: [definition]), protectsAuthoredWork: true
        )
        let result = await ScanProbe.run(store.definitions())

        let finding = try #require(result.findings.first)
        // Found and measured, but there is no path from here to a removal: the
        // checkbox, the planner and the executor all refuse it in turn.
        #expect(finding.allocatedSize >= 100_000)
        #expect(finding.holdsAuthoredWork)
        #expect(finding.isSelectable == false)

        let plan = RemovalPlan.plan(for: [finding], definitions: store.definitions())
        #expect(plan.trashOperations.isEmpty)

        let receipt = RemovalExecutor(
            definitions: store.definitions(),
            trash: { _ in Issue.record("a protected path reached the Trash"); return nil }
        ).execute([finding])
        #expect(receipt.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: tree.root.appending(path: "history/session.jsonl").path))
    }
}

/// The grades themselves, checked against the shipped catalogue. A rule can be
/// protected and still be wrongly graded, and the grade is what a bulk action
/// reads.
@Suite("Grades on shipped rules")
struct ShippedGradeTests {

    @Test("Nothing that holds authored work is graded safe")
    func authoredWorkIsNeverSafe() {
        for rule in Catalogue.all where rule.holdsAuthoredWork {
            // `.safe` is what "Select safe items" ticks. History does not
            // belong in a bulk action, protection on or off.
            #expect(
                rule.grade != .safe,
                "\(rule.id) holds authored work and is graded safe"
            )
        }
    }

    @Test("The assistant transcripts rule is protected and never safe")
    func transcriptsRuleIsProtected() throws {
        let transcripts = try #require(
            Catalogue.all.first { $0.id == "xcode.coding-assistant.transcripts" }
        )

        // The specific rule this suite was written for.
        #expect(transcripts.holdsAuthoredWork)
        #expect(transcripts.grade != .safe)
    }

    @Test("Assistant edit checkpoints are protected too")
    func snapshotsRuleIsProtected() throws {
        let snapshots = try #require(
            Catalogue.all.first { $0.id == "xcode.coding-assistant.snapshots" }
        )

        #expect(snapshots.holdsAuthoredWork)
    }

    @Test("A local artefact store that nothing can re-download is protected")
    func mavenRepositoryIsProtected() throws {
        let maven = try #require(Catalogue.all.first { $0.id == "caches.maven" })

        // Published dependencies come back; anything installed only locally
        // does not, and Attic cannot tell the two apart.
        #expect(maven.holdsAuthoredWork)
        #expect(maven.grade == .checkFirst)
    }

    @Test("With protection on, nothing the shipped catalogue offers is authored work")
    func shippedCatalogueOffersNoAuthoredWork() {
        for rule in DefinitionStore().definitions() where rule.status == .active {
            #expect(
                rule.holdsAuthoredWork == false,
                "\(rule.id) is offered by default and holds authored work"
            )
        }
    }
}

/// The toggle, and the promise that it is remembered.
@Suite("The protection switch")
@MainActor
struct ProtectionSwitchTests {

    private func model(protecting: Bool) -> (ScanModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: "attic.tests.\(UUID().uuidString)")!
        let settings = AtticSettings(defaults: defaults)
        settings.protectsAuthoredWork = protecting
        return (
            ScanModel(store: DefinitionStore(source: NoRules()), settings: settings),
            defaults
        )
    }

    @Test("The model starts from what was remembered")
    func modelReadsTheStoredSetting() {
        #expect(model(protecting: true).0.protectsAuthoredWork)
        #expect(model(protecting: false).0.protectsAuthoredWork == false)
    }

    @Test("Changing the switch is remembered for next launch")
    func changesPersist() {
        let (subject, defaults) = model(protecting: true)

        subject.setProtectsAuthoredWork(false)

        #expect(subject.protectsAuthoredWork == false)
        // A safety setting that only lived in memory would quietly come back on
        // — or worse, quietly stay off.
        #expect(AtticSettings(defaults: defaults).protectsAuthoredWork == false)
    }

    @Test("Setting it to what it already is does nothing")
    func settingTheSameValueIsANoOp() {
        let (subject, _) = model(protecting: true)

        subject.setProtectsAuthoredWork(true)

        #expect(subject.protectsAuthoredWork)
        #expect(subject.phase == .firstRun)
    }
}

private struct StubRules: DefinitionSource {
    let rules: [RuleDefinition]

    func load() throws -> [RuleDefinition] { rules }
}

private struct NoRules: DefinitionSource {
    func load() throws -> [RuleDefinition] { [] }
}
