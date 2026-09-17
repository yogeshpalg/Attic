import Foundation

// MARK: - Trust policy

/// What a fetched rule is allowed to do.
///
/// A signature proves a catalogue came from the right key. It does not make the
/// rule inside it a good idea, and a signing key can leak. So a fetched rule may
/// arrive ready to use, but only within the blast radius of the thing Attic is
/// least able to do damage with: moving a user-owned file to the Trash, where it
/// can be dragged back out.
///
/// Anything beyond that — running a command, needing administrator rights,
/// evicting an iCloud copy, or touching authored work — is reported and
/// explained but never offered, until a build of the app promotes it. Those are
/// decisions that should go through a release, not a download.
enum FetchedRulePolicy {

    /// Demotes rather than drops. A refused rule that vanished would leave the
    /// user with a gigabyte they cannot see and no explanation; detect-only
    /// shows the size and the reasoning and offers no checkbox.
    static func clamp(_ rule: RuleDefinition) -> RuleDefinition {
        guard rule.status == .active, !isWithinFetchedLimits(rule) else { return rule }

        var demoted = rule
        demoted.status = .detectOnly
        return demoted
    }

    static func isWithinFetchedLimits(_ rule: RuleDefinition) -> Bool {
        guard rule.action == .trash else { return false }
        guard rule.privilege == .user else { return false }
        guard !rule.holdsAuthoredWork else { return false }
        return rule.grade == .safe || rule.grade == .checkFirst
    }
}

// MARK: - Cache

/// The last catalogue that verified, kept so Attic is not dependent on the
/// network to know what it knew yesterday.
struct DefinitionCache: Sendable {

    let directory: URL

    init(directory: URL = DefinitionCache.defaultDirectory) {
        self.directory = directory
    }

    /// `~/Library/Application Support/dev.yogesh.attic`. Not in Caches: a cache
    /// directory is something Attic itself would offer to delete.
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support")

        let identifier = Bundle.main.bundleIdentifier ?? "dev.yogesh.attic"
        return support.appending(path: identifier)
    }

    var file: URL { directory.appending(path: "definitions.json") }

    func store(_ document: SignedCatalogue) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try CatalogueCoding.encoder.encode(document)
        try data.write(to: file, options: .atomic)
    }

    func document() -> SignedCatalogue? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? CatalogueCoding.decoder.decode(SignedCatalogue.self, from: data)
    }

    /// Re-verifies on every read. The file is user-writable, so a cached
    /// catalogue earns no more trust than one off the network.
    func payload(verifier: CatalogueVerifier) -> CataloguePayload? {
        guard let document = document() else { return nil }
        return try? verifier.verify(document)
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Transport

/// The one network call Attic makes, behind a protocol so tests never reach the
/// network and the updater can be exercised offline.
protocol DefinitionTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

struct NetworkTransport: DefinitionTransport {
    func data(from url: URL) async throws -> Data {
        // No caching layer: the document carries its own version and signature,
        // and a stale 200 from a proxy is indistinguishable from a downgrade.
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}

// MARK: - Updater

/// Fetch, verify, refuse a downgrade, cache. In that order, and it stops at the
/// first step that fails.
struct DefinitionUpdater: Sendable {

    let feed: URL
    let transport: DefinitionTransport
    let verifier: CatalogueVerifier
    let cache: DefinitionCache

    init(
        feed: URL,
        transport: DefinitionTransport = NetworkTransport(),
        verifier: CatalogueVerifier = CatalogueVerifier(),
        cache: DefinitionCache = DefinitionCache()
    ) {
        self.feed = feed
        self.transport = transport
        self.verifier = verifier
        self.cache = cache
    }

    @discardableResult
    func update() async throws -> CataloguePayload {
        let data = try await transport.data(from: feed)

        guard let document = try? CatalogueCoding.decoder
            .decode(SignedCatalogue.self, from: data)
        else { throw DefinitionTrustError.malformedDocument }

        let offered = try verifier.verify(document)

        // Checked after verification, so an unsigned file cannot tell Attic
        // anything at all — including which version it claims to be.
        if let cached = cache.payload(verifier: verifier),
           offered.catalogueVersion < cached.catalogueVersion {
            throw DefinitionTrustError.downgrade(
                cached: cached.catalogueVersion,
                offered: offered.catalogueVersion
            )
        }

        try cache.store(document)
        return offered
    }
}

// MARK: - Source

/// Where the app gets its rules once a catalogue has been fetched.
///
/// Fetched rules are merged over the compiled ones by id rather than replacing
/// them wholesale. A partial or truncated catalogue then costs coverage it did
/// not mean to remove, and retiring a rule remotely still works — the update
/// says so explicitly, with `maxOSVersion` or `detectOnly`, instead of achieving
/// it by omission.
struct RemoteDefinitionSource: DefinitionSource {

    let cache: DefinitionCache
    let verifier: CatalogueVerifier
    let builtIn: [RuleDefinition]

    init(
        cache: DefinitionCache = DefinitionCache(),
        verifier: CatalogueVerifier = CatalogueVerifier(),
        builtIn: [RuleDefinition] = Catalogue.all
    ) {
        self.cache = cache
        self.verifier = verifier
        self.builtIn = builtIn
    }

    /// Non-throwing in practice: anything wrong with the cached catalogue means
    /// the compiled rules, which are always present.
    func load() throws -> [RuleDefinition] {
        guard let payload = cache.payload(verifier: verifier) else { return builtIn }
        return DefinitionMerge.overlay(payload.rules.map(FetchedRulePolicy.clamp), onto: builtIn)
    }

    /// What the About window shows, or `nil` when the compiled rules are all
    /// there is.
    var provenance: DefinitionProvenance? {
        guard let payload = cache.payload(verifier: verifier) else { return nil }
        return DefinitionProvenance(
            catalogueVersion: payload.catalogueVersion,
            published: payload.published,
            ruleCount: payload.rules.count
        )
    }
}

/// Which catalogue is running, so "the app is wrong" and "the app is out of
/// date" are distinguishable without reading a log.
struct DefinitionProvenance: Sendable, Equatable {
    let catalogueVersion: Int
    let published: Date
    let ruleCount: Int
}
