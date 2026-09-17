import Foundation
import Testing

@testable import Attic

/// What a file somebody wrote themselves is allowed to do.
///
/// The format being open is the point — whoever knows where their toolchain
/// hides two gigabytes can say so. What these tests defend is that opening the
/// format did not open the blast radius with it: an imported rule still cannot
/// run a command, still cannot claim administrator rights, and still cannot
/// quietly remove a protection from a rule that has one.
@Suite("Imported definitions are validated before they are trusted")
struct CustomDefinitionValidationTests {

    @Test("A well-formed catalogue is accepted")
    func wellFormedCatalogueIsAccepted() throws {
        let data = try encode(CustomCatalogue(rules: [.fixture(id: "custom.cache", root: anyRoot)]))
        #expect(try CustomDefinitionStore.validate(data).rules.count == 1)
    }

    @Test("A bare array of rules is accepted too")
    func bareArrayIsAccepted() throws {
        // The wrapper is exactly the kind of detail that makes someone give up
        // on their first hand-written file.
        let data = try CatalogueCoding.encoder.encode([RuleDefinition.fixture(root: anyRoot)])
        #expect(try CustomDefinitionStore.validate(data).rules.count == 1)
    }

    @Test("A rule that runs a command is refused outright")
    func commandsAreRefused() throws {
        let data = try encode(CustomCatalogue(rules: [
            .fixture(id: "custom.ok", root: anyRoot),
            .fixture(id: "custom.runs-things", root: anyRoot, action: .command(.brewCleanup)),
        ]))

        // Not demoted — refused. "Import these definitions" must never be a way
        // to say "run this for me", even from the allowlist.
        #expect(throws: CustomDefinitionError.commandsNotAllowed(["custom.runs-things"])) {
            try CustomDefinitionStore.validate(data)
        }
    }

    @Test("A rule that cannot explain itself is refused")
    func unexplainedRulesAreRefused() throws {
        var rule = RuleDefinition.fixture(id: "custom.silent", root: anyRoot)
        rule = RuleDefinition(
            id: rule.id, minAppVersion: rule.minAppVersion,
            category: rule.category, displayName: rule.displayName,
            root: rule.root, match: rule.match, exclude: rule.exclude,
            grouping: rule.grouping, retention: rule.retention,
            subtitleStyle: rule.subtitleStyle, applicability: rule.applicability,
            action: rule.action, privilege: rule.privilege, grade: rule.grade,
            status: rule.status,
            explanation: Explanation(whatThisIs: "", whatStopsWorking: "", doesItComeBack: "")
        )

        #expect(throws: CustomDefinitionError.missingExplanation(["custom.silent"])) {
            try CustomDefinitionStore.validate(try encode(CustomCatalogue(rules: [rule])))
        }
    }

    @Test("A name containing a path is refused")
    func pathsInNamesAreRefused() throws {
        let rule = RuleDefinition(
            id: "custom.leaky", minAppVersion: "1.0",
            category: .cachesAndLogs, displayName: "~/Library/Caches/thing",
            root: .absolute(anyRoot.path), match: .wholeRoot, exclude: [],
            grouping: .single, retention: .none, subtitleStyle: .fileCount,
            applicability: .rootExists, action: .trash, privilege: .user,
            grade: .safe, status: .active,
            explanation: Explanation(whatThisIs: "A.", whatStopsWorking: "B.", doesItComeBack: "C.")
        )

        #expect(throws: CustomDefinitionError.pathsInDisplayName(["custom.leaky"])) {
            try CustomDefinitionStore.validate(try encode(CustomCatalogue(rules: [rule])))
        }
    }

    @Test("Two rules sharing an id are refused")
    func duplicateIDsAreRefused() throws {
        let data = try encode(CustomCatalogue(rules: [
            .fixture(id: "same", root: anyRoot),
            .fixture(id: "same", root: anyRoot),
        ]))

        #expect(throws: CustomDefinitionError.duplicateIdentifiers(["same"])) {
            try CustomDefinitionStore.validate(data)
        }
    }

    @Test("A rule can leave out anything that has a cautious default")
    func defaultsFillInForHandWrittenRules() throws {
        // The minimum somebody should have to write: where to look, what it
        // matches, what happens, and the three sentences.
        let json = """
            {
              "formatVersion": 1,
              "rules": [
                {
                  "id": "mine.minimal",
                  "category": "cachesAndLogs",
                  "displayName": "My tool cache",
                  "root": { "home": { "_0": "Library/Caches/com.example.mine" } },
                  "match": { "wholeRoot": {} },
                  "action": { "trash": {} },
                  "explanation": {
                    "whatThisIs": "A cache.",
                    "whatStopsWorking": "Nothing.",
                    "doesItComeBack": "Yes."
                  }
                }
              ]
            }
            """

        let rule = try #require(try CustomDefinitionStore.validate(Data(json.utf8)).rules.first)

        #expect(rule.exclude.isEmpty)
        #expect(rule.privilege == .user)
        #expect(rule.applicability == .rootExists)
        #expect(rule.retention == .none)
        // Cautious where it costs nothing: a rule nobody graded is never swept
        // up by "Select safe".
        #expect(rule.grade == .checkFirst)
        #expect(rule.holdsAuthoredWork == false)
        #expect(rule.minAppVersion == "1.0")
    }

    @Test("A missing required field is named, not hidden behind 'unreadable'")
    func missingFieldsAreNamed() throws {
        // No root: the one field whose absence cannot be defaulted, because
        // there is nowhere to look.
        let json = """
            {
              "formatVersion": 1,
              "rules": [
                { "id": "mine.broken", "category": "cachesAndLogs", "displayName": "X",
                  "match": { "wholeRoot": {} }, "action": { "trash": {} },
                  "explanation": { "whatThisIs": "A.", "whatStopsWorking": "B.", "doesItComeBack": "C." } }
              ]
            }
            """

        do {
            _ = try CustomDefinitionStore.validate(Data(json.utf8))
            Issue.record("a rule with no root should not validate")
        } catch let error as CustomDefinitionError {
            // The author just wrote this file. The message has to say which
            // field, and which rule, or they are reduced to guessing.
            #expect(error.message.contains("root"))
            #expect(error.message.contains("rule 1"))
        }
    }

    @Test("An empty catalogue and unreadable bytes are both refused")
    func emptyAndUnreadableAreRefused() throws {
        #expect(throws: CustomDefinitionError.noRules) {
            try CustomDefinitionStore.validate(try encode(CustomCatalogue(rules: [])))
        }
        #expect(throws: CustomDefinitionError.unreadable) {
            try CustomDefinitionStore.validate(Data("nonsense".utf8))
        }
    }

    @Test("A format this build does not read is refused")
    func futureFormatIsRefused() throws {
        var catalogue = CustomCatalogue(rules: [.fixture(root: anyRoot)])
        catalogue.formatVersion = CataloguePayload.supportedFormatVersion + 1

        #expect(throws: CustomDefinitionError.unsupportedFormat(
            offered: CataloguePayload.supportedFormatVersion + 1,
            supported: CataloguePayload.supportedFormatVersion
        )) {
            try CustomDefinitionStore.validate(try encode(catalogue))
        }
    }

    @Test("The exported template is a catalogue this build would accept back")
    func templateRoundTrips() throws {
        // The template is the authoring starting point, so it has to satisfy the
        // same validator an imported file does — otherwise the first thing
        // somebody edits is already invalid.
        let template = try CustomDefinitionStore.template()
        let parsed = try CustomDefinitionStore.validate(template)

        #expect(parsed.rules.isEmpty == false)
        // Command rules are refused on import, so they are left out rather than
        // exported into a file that would fail the moment it came back.
        #expect(parsed.rules.allSatisfy { if case .command = $0.action { false } else { true } })
        #expect(parsed.rules.count < Catalogue.all.count)

        // The instructions travel with the file, because JSON has no comments
        // and the person who opens this months from now will not have the docs
        // in front of them.
        let help = try #require(parsed.help)
        #expect(help.contains("Import"))
        #expect(help.contains("DEFINITIONS.md"))
    }

    @Test("A file without the help note is still valid")
    func helpNoteIsOptional() throws {
        // Hand-written files will not carry it, and it is documentation rather
        // than data — validating it would turn a note into a requirement.
        let data = try encode(CustomCatalogue(rules: [.fixture(root: anyRoot)]))
        let parsed = try CustomDefinitionStore.validate(data)

        #expect(parsed.help == nil)
        #expect(parsed.rules.count == 1)
    }

    @Test("An unknown key in a hand-written file is ignored rather than refused")
    func unknownKeysAreTolerated() throws {
        // People leave notes in JSON files. Refusing a catalogue over a stray
        // key would be pedantry, not safety.
        let json = """
            {
              "formatVersion": 1,
              "_note": "my own comment",
              "rules": [
                {
                  "id": "mine.cache",
                  "minAppVersion": "1.0",
                  "category": "cachesAndLogs",
                  "displayName": "My tool cache",
                  "root": { "home": { "_0": "Library/Caches/com.example.mine" } },
                  "match": { "wholeRoot": {} },
                  "exclude": [],
                  "grouping": "single",
                  "retention": { "none": {} },
                  "subtitleStyle": "fileCount",
                  "applicability": { "rootExists": {} },
                  "action": { "trash": {} },
                  "privilege": "user",
                  "grade": "safe",
                  "status": "active",
                  "explanation": {
                    "whatThisIs": "A cache.",
                    "whatStopsWorking": "Nothing.",
                    "doesItComeBack": "Yes."
                  }
                }
              ]
            }
            """

        let parsed = try CustomDefinitionStore.validate(Data(json.utf8))
        #expect(parsed.rules.first?.id == "mine.cache")
    }
}

/// Importing, keeping, and removing the user's rules.
@Suite("The custom catalogue survives a bad import and a bad edit")
struct CustomDefinitionStoreTests {

    @Test("Importing writes rules that load back clamped")
    func importedRulesLoadBack() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        let count = try harness.store.replace(with: try encode(CustomCatalogue(rules: [
            .fixture(id: "mine.cache", root: harness.directory),
            .fixture(id: "mine.admin", root: harness.directory, privilege: .administrator),
        ])))

        #expect(count == 2)
        let loaded = Dictionary(uniqueKeysWithValues: harness.store.rules().map { ($0.id, $0) })
        #expect(loaded["mine.cache"]?.status == .active)
        // Beyond the limits, so found and explained but never offered.
        #expect(loaded["mine.admin"]?.status == .detectOnly)
    }

    @Test("A refused import leaves the previous rules in place")
    func refusedImportKeepsPreviousRules() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        try harness.store.replace(with: try encode(CustomCatalogue(rules: [
            .fixture(id: "mine.first", root: harness.directory),
        ])))

        #expect(throws: (any Error).self) {
            try harness.store.replace(with: Data("broken".utf8))
        }
        #expect(harness.store.rules().map(\.id) == ["mine.first"])
    }

    @Test("A file edited by hand after import gets the same limits")
    func handEditedFileIsStillClamped() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        // Written straight to disk, bypassing the importer entirely — the
        // clamp has to live on the read path as well as the write path.
        try encode(CustomCatalogue(rules: [
            .fixture(id: "mine.sneaky", root: harness.directory, privilege: .administrator),
        ])).write(to: harness.store.file)

        #expect(harness.store.rules().first?.status == .detectOnly)
    }

    @Test("A corrupt file reads as no rules rather than a crash")
    func corruptFileIsIgnored() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        try Data("{".utf8).write(to: harness.store.file)
        #expect(harness.store.rules().isEmpty)
        #expect(harness.store.exists)
    }

    @Test("Removing the file removes the rules")
    func removalClearsRules() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        try harness.store.replace(with: try encode(CustomCatalogue(rules: [
            .fixture(id: "mine.only", root: harness.directory),
        ])))
        harness.store.remove()

        #expect(harness.store.exists == false)
        #expect(harness.store.rules().isEmpty)
    }
}

/// How the three layers combine.
@Suite("Custom rules layer over official ones, which layer over compiled ones")
struct LayeredDefinitionTests {

    @Test("With no catalogue and no custom file, the compiled rules are used")
    func compiledRulesAreTheFloor() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        let compiled = [RuleDefinition.fixture(id: "compiled", root: harness.directory)]
        #expect(try harness.source(builtIn: compiled).load().map(\.id) == ["compiled"])
    }

    @Test("A custom rule overrides a compiled rule with the same id")
    func customRuleOverridesCompiled() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        let compiled = [
            RuleDefinition.fixture(id: "shared", root: harness.directory, grade: .safe),
            RuleDefinition.fixture(id: "untouched", root: harness.directory),
        ]
        try harness.store.replace(with: try encode(CustomCatalogue(rules: [
            .fixture(id: "shared", root: harness.directory, grade: .checkFirst),
            .fixture(id: "mine", root: harness.directory),
        ])))

        let byID = Dictionary(
            uniqueKeysWithValues: try harness.source(builtIn: compiled).load().map { ($0.id, $0) }
        )
        #expect(byID["shared"]?.grade == .checkFirst)
        #expect(byID["untouched"] != nil)
        #expect(byID["mine"] != nil)
    }

    @Test("A custom rule cannot strip the authored-work protection off a compiled one")
    func customRulesCannotStripProtection() throws {
        let harness = try CustomHarness()
        defer { harness.destroy() }

        let compiled = [
            RuleDefinition.fixture(
                id: "transcripts", root: harness.directory,
                grade: .checkFirst, holdsAuthoredWork: true
            )
        ]
        // The file that would have cost five projects their history: same id,
        // re-graded safe, flag quietly absent.
        try harness.store.replace(with: try encode(CustomCatalogue(rules: [
            .fixture(id: "transcripts", root: harness.directory, grade: .safe),
        ])))

        let loaded = try #require(
            try harness.source(builtIn: compiled).load().first { $0.id == "transcripts" }
        )
        #expect(loaded.holdsAuthoredWork)
        #expect(loaded.status == .detectOnly)
    }
}

// MARK: - Harness

private var anyRoot: URL {
    URL(fileURLWithPath: "/tmp/attic-custom-definition-tests")
}

private func encode(_ catalogue: CustomCatalogue) throws -> Data {
    try CatalogueCoding.encoder.encode(catalogue)
}

/// A store rooted in a temporary directory, so no test writes to the real
/// Application Support folder.
private struct CustomHarness {
    let directory: URL
    let store: CustomDefinitionStore

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "attic-custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CustomDefinitionStore(directory: directory)
    }

    /// An official layer with nothing cached, so these tests see only the
    /// compiled rules and the custom file.
    func source(builtIn: [RuleDefinition]) -> LayeredDefinitionSource {
        LayeredDefinitionSource(
            official: RemoteDefinitionSource(
                cache: DefinitionCache(directory: directory),
                verifier: CatalogueVerifier(base64Key: ""),
                builtIn: builtIn
            ),
            custom: store
        )
    }

    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }
}
