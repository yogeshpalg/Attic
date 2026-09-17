import Foundation

/// A catalogue somebody wrote themselves.
///
/// Unsigned, because requiring a signature here would mean only the project can
/// author rules, and the whole point of the format being open is that the person
/// who knows where their toolchain hides two gigabytes can say so without asking
/// anyone. What replaces the signature is that the user chose the file — and the
/// limits below, which do not widen just because a rule arrived locally.
struct CustomCatalogue: Codable, Sendable, Equatable {
    var formatVersion: Int
    var rules: [RuleDefinition]

    init(formatVersion: Int = CataloguePayload.supportedFormatVersion, rules: [RuleDefinition]) {
        self.formatVersion = formatVersion
        self.rules = rules
    }
}

/// Why an imported file was not accepted. Each case names the rules at fault, so
/// the message can point at the line to fix rather than saying "invalid".
enum CustomDefinitionError: Error, Equatable {
    case unreadable
    case unsupportedFormat(offered: Int, supported: Int)
    case noRules
    case duplicateIdentifiers([String])
    /// Commands are code execution. An allowlisted command still has to come
    /// from a build of the app, never from a file — otherwise "import these
    /// definitions" becomes "run this for me".
    case commandsNotAllowed([String])
    case missingExplanation([String])
    case pathsInDisplayName([String])

    var message: String {
        switch self {
        case .unreadable:
            "That file could not be read as a definitions catalogue."
        case .unsupportedFormat(let offered, let supported):
            "That file uses format \(offered); this version of Attic reads format \(supported)."
        case .noRules:
            "That file contains no rules."
        case .duplicateIdentifiers(let ids):
            "Two rules share an id: \(ids.joined(separator: ", "))."
        case .commandsNotAllowed(let ids):
            "Imported rules cannot run commands: \(ids.joined(separator: ", "))."
        case .missingExplanation(let ids):
            "Every rule needs all three explanation sentences: \(ids.joined(separator: ", "))."
        case .pathsInDisplayName(let ids):
            "A rule's name is shown to people and cannot contain a path: \(ids.joined(separator: ", "))."
        }
    }
}

/// Reads, validates and keeps the user's own rules.
struct CustomDefinitionStore: Sendable {

    let directory: URL

    init(directory: URL = DefinitionCache.defaultDirectory) {
        self.directory = directory
    }

    var file: URL { directory.appending(path: "custom-definitions.json") }

    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Clamped on the way out as well as checked on the way in, so a file edited
    /// by hand after import gets the same limits as one that came through it.
    func rules() -> [RuleDefinition] {
        guard let data = try? Data(contentsOf: file),
              let catalogue = try? Self.validate(data)
        else { return [] }
        return catalogue.rules.map(FetchedRulePolicy.clamp)
    }

    var ruleCount: Int { rules().count }

    /// Validates first and writes second, so a bad import leaves the previous
    /// custom rules in place rather than replacing them with nothing.
    @discardableResult
    func replace(withContentsOf source: URL) throws -> Int {
        guard let data = try? Data(contentsOf: source) else {
            throw CustomDefinitionError.unreadable
        }
        return try replace(with: data)
    }

    @discardableResult
    func replace(with data: Data) throws -> Int {
        let catalogue = try Self.validate(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CatalogueCoding.encoder.encode(catalogue).write(to: file, options: .atomic)
        return catalogue.rules.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Validation

    /// Accepts either a wrapped catalogue or a bare array of rules, because a
    /// hand-written file is the normal case here and the wrapper is the kind of
    /// detail that makes someone give up on the first try.
    static func validate(_ data: Data) throws -> CustomCatalogue {
        let decoder = CatalogueCoding.decoder
        let catalogue: CustomCatalogue

        if let wrapped = try? decoder.decode(CustomCatalogue.self, from: data) {
            catalogue = wrapped
        } else if let bare = try? decoder.decode([RuleDefinition].self, from: data) {
            catalogue = CustomCatalogue(rules: bare)
        } else {
            throw CustomDefinitionError.unreadable
        }

        guard catalogue.formatVersion == CataloguePayload.supportedFormatVersion else {
            throw CustomDefinitionError.unsupportedFormat(
                offered: catalogue.formatVersion,
                supported: CataloguePayload.supportedFormatVersion
            )
        }
        guard !catalogue.rules.isEmpty else { throw CustomDefinitionError.noRules }

        let ids = catalogue.rules.map(\.id)
        let duplicates = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        guard duplicates.isEmpty else {
            throw CustomDefinitionError.duplicateIdentifiers(duplicates.sorted())
        }

        let commands = catalogue.rules.filter {
            if case .command = $0.action { return true } else { return false }
        }
        guard commands.isEmpty else {
            throw CustomDefinitionError.commandsNotAllowed(commands.map(\.id).sorted())
        }

        // The three sentences are the app's whole promise. A rule that cannot
        // explain itself has no business offering a checkbox.
        let unexplained = catalogue.rules.filter {
            $0.explanation.whatThisIs.isEmpty
                || $0.explanation.whatStopsWorking.isEmpty
                || $0.explanation.doesItComeBack.isEmpty
                || $0.displayName.isEmpty
        }
        guard unexplained.isEmpty else {
            throw CustomDefinitionError.missingExplanation(unexplained.map(\.id).sorted())
        }

        let pathNames = catalogue.rules.filter { $0.displayName.contains("/") }
        guard pathNames.isEmpty else {
            throw CustomDefinitionError.pathsInDisplayName(pathNames.map(\.id).sorted())
        }

        return catalogue
    }

    /// The built-in rules, written out as a file somebody can edit.
    ///
    /// This is the starting point for authoring: 20-odd worked examples of the
    /// format, rather than a schema to read and guess at.
    ///
    /// Command rules are left out, because imported rules cannot run commands —
    /// a template that included them would hand somebody a file that fails the
    /// moment they import it back, and the first thing they would learn about
    /// the format is that it does not work.
    static func template(from rules: [RuleDefinition] = Catalogue.all) throws -> Data {
        let authorable = rules.filter {
            if case .command = $0.action { return false } else { return true }
        }
        let encoder = CatalogueCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(CustomCatalogue(rules: authorable))
    }
}

// MARK: - Merging

/// One place where "these rules replace those rules" is decided, used by both
/// the official and the custom layer.
enum DefinitionMerge {

    /// Overlays by id, keeping anything the overlay does not mention.
    ///
    /// A catalogue that omits a rule has not retired it — retiring is stated,
    /// with `maxOSVersion` or `detectOnly`, rather than achieved by leaving a
    /// rule out of a file that might simply have been truncated.
    static func overlay(
        _ overlay: [RuleDefinition], onto base: [RuleDefinition]
    ) -> [RuleDefinition] {
        var merged = base
        let positions = Dictionary(
            base.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        for rule in overlay {
            if let index = positions[rule.id] {
                merged[index] = inheritingProtection(rule, from: merged[index])
            } else {
                merged.append(rule)
            }
        }
        return merged
    }

    /// `holdsAuthoredWork` is sticky per rule id.
    ///
    /// Without this, a catalogue could override the transcripts rule with a copy
    /// that simply does not carry the flag, and a protection somebody relies on
    /// would be gone in a file they never read. A rule can gain the flag from an
    /// update; it can never lose it.
    static func inheritingProtection(
        _ incoming: RuleDefinition, from existing: RuleDefinition
    ) -> RuleDefinition {
        guard existing.holdsAuthoredWork, !incoming.holdsAuthoredWork else { return incoming }

        var protected = incoming
        protected.holdsAuthoredWork = true
        return FetchedRulePolicy.clamp(protected)
    }
}

/// The catalogue the app actually runs: compiled rules, then official signed
/// updates over them, then the user's own rules over those.
///
/// Last layer wins by id, and every layer above the compiled one is clamped —
/// so the order decides which rule is used, never how much a rule is allowed
/// to do.
struct LayeredDefinitionSource: DefinitionSource {

    let official: RemoteDefinitionSource
    let custom: CustomDefinitionStore

    init(
        official: RemoteDefinitionSource = RemoteDefinitionSource(),
        custom: CustomDefinitionStore = CustomDefinitionStore()
    ) {
        self.official = official
        self.custom = custom
    }

    func load() throws -> [RuleDefinition] {
        let base = try official.load()
        let mine = custom.rules()
        guard !mine.isEmpty else { return base }
        return DefinitionMerge.overlay(mine, onto: base)
    }
}
