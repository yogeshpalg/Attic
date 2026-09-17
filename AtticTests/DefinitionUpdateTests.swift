import CryptoKit
import Foundation
import Testing

@testable import Attic

/// What a signature is actually for.
///
/// These tests defend the one thing that makes a fetched catalogue safe to run
/// at all: nothing is believed without a valid signature from the key this build
/// trusts — not a download, not the copy on disk, not a file claiming to be
/// newer than it is. Every failure here means rules from an unknown source could
/// reach the engine that deletes things.
@Suite("A catalogue is only believed when it is signed by the trusted key")
struct CatalogueTrustTests {

    @Test("A catalogue signed by the trusted key verifies")
    func signedCatalogueVerifies() throws {
        let signer = TestSigner()
        let document = try signer.sign(payload(version: 4, rules: [.fixture(root: anyRoot)]))

        let payload = try signer.verifier.verify(document)

        #expect(payload.catalogueVersion == 4)
        #expect(payload.rules.count == 1)
    }

    @Test("A payload edited after signing is refused")
    func tamperedPayloadIsRefused() throws {
        let signer = TestSigner()
        let original = try signer.sign(payload(version: 1, rules: [.fixture(root: anyRoot)]))

        // A single flipped rule, re-encoded and dropped into the same envelope:
        // exactly what an attacker with write access to the feed would do.
        let swapped = try signer.encodePayload(
            payload(version: 1, rules: [.fixture(id: "attacker.rule", root: anyRoot)])
        )
        let tampered = SignedCatalogue(
            payload: swapped.base64EncodedString(),
            signature: original.signature
        )

        #expect(throws: DefinitionTrustError.badSignature) {
            try signer.verifier.verify(tampered)
        }
    }

    @Test("A catalogue signed by some other key is refused")
    func otherKeyIsRefused() throws {
        let attacker = TestSigner()
        let document = try attacker.sign(payload(version: 1, rules: []))

        #expect(throws: DefinitionTrustError.badSignature) {
            try TestSigner().verifier.verify(document)
        }
    }

    @Test("With no key compiled in, every catalogue is refused")
    func noTrustedKeyRefusesEverything() throws {
        let signer = TestSigner()
        let document = try signer.sign(payload(version: 1, rules: []))

        // The shipping default until a key exists. An unset key must never mean
        // "accept anything"; it means the compiled rules are all there are.
        let verifier = CatalogueVerifier(base64Key: "")
        #expect(verifier.hasTrustedKey == false)
        #expect(throws: DefinitionTrustError.noTrustedKey) {
            try verifier.verify(document)
        }
    }

    @Test("A format this build does not understand is refused rather than partly read")
    func futureFormatIsRefused() throws {
        let signer = TestSigner()
        let document = try signer.sign(
            CataloguePayload(
                formatVersion: CataloguePayload.supportedFormatVersion + 1,
                catalogueVersion: 9,
                published: Date(timeIntervalSince1970: 0),
                rules: []
            )
        )

        #expect(throws: DefinitionTrustError.unsupportedFormat(
            offered: CataloguePayload.supportedFormatVersion + 1,
            supported: CataloguePayload.supportedFormatVersion
        )) {
            try signer.verifier.verify(document)
        }
    }
}

/// Fetching, caching, and the two ways a good signature is still not enough.
@Suite("Updating keeps the last good catalogue and refuses to go backwards")
struct DefinitionUpdaterTests {

    @Test("A verified catalogue is cached and read back")
    func updateCaches() async throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let document = try harness.signer.sign(
            payload(version: 2, rules: [.fixture(id: "fetched.rule", root: harness.directory)])
        )
        let updated = try await harness.updater(serving: document).update()

        #expect(updated.catalogueVersion == 2)
        #expect(harness.cache.payload(verifier: harness.signer.verifier)?.catalogueVersion == 2)
    }

    @Test("An older catalogue cannot replace a newer one")
    func downgradeIsRefused() async throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let newer = try harness.signer.sign(payload(version: 7, rules: []))
        try harness.cache.store(newer)

        // Correctly signed, simply old — a replayed file that would roll back a
        // correction made in version 7.
        let older = try harness.signer.sign(payload(version: 6, rules: []))

        await #expect(throws: DefinitionTrustError.downgrade(cached: 7, offered: 6)) {
            try await harness.updater(serving: older).update()
        }
        #expect(harness.cache.payload(verifier: harness.signer.verifier)?.catalogueVersion == 7)
    }

    @Test("The same version is accepted, so a corrected republish still lands")
    func sameVersionIsAccepted() async throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        try harness.cache.store(try harness.signer.sign(payload(version: 3, rules: [])))
        let republished = try harness.signer.sign(
            payload(version: 3, rules: [.fixture(id: "corrected", root: harness.directory)])
        )

        let updated = try await harness.updater(serving: republished).update()
        #expect(updated.rules.first?.id == "corrected")
    }

    @Test("A failed fetch leaves the cached catalogue alone")
    func failedFetchKeepsCache() async throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        try harness.cache.store(try harness.signer.sign(payload(version: 5, rules: [])))

        let updater = DefinitionUpdater(
            feed: harness.feed,
            transport: FailingTransport(),
            verifier: harness.signer.verifier,
            cache: harness.cache
        )

        await #expect(throws: (any Error).self) { try await updater.update() }
        #expect(harness.cache.payload(verifier: harness.signer.verifier)?.catalogueVersion == 5)
    }

    @Test("A feed with nothing on it yet is not reported as a failure")
    func emptyFeedIsNotAnError() {
        // This is what lets the feed URL ship in a build before the first
        // catalogue is published: 404 means "nothing published", which is true.
        #expect(NetworkTransport.outcome(for: 404) == .notPublished)
        #expect(NetworkTransport.outcome(for: 410) == .notPublished)

        // Success is success, including the ones nobody expects.
        #expect(NetworkTransport.outcome(for: 200) == nil)
        #expect(NetworkTransport.outcome(for: 204) == nil)

        // Everything else keeps its status, so a broken host and an empty one
        // are never confused in the message the user reads.
        #expect(NetworkTransport.outcome(for: 500) == .serverError(status: 500))
        #expect(NetworkTransport.outcome(for: 403) == .serverError(status: 403))
        #expect(NetworkTransport.outcome(for: 503) == .serverError(status: 503))
    }

    @Test("Bytes that are not a catalogue at all are refused")
    func garbageIsRefused() async throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let updater = DefinitionUpdater(
            feed: harness.feed,
            transport: StubTransport(data: Data("not a catalogue".utf8)),
            verifier: harness.signer.verifier,
            cache: harness.cache
        )

        await #expect(throws: DefinitionTrustError.malformedDocument) {
            try await updater.update()
        }
    }
}

/// The limits a fetched rule runs inside, and the fallback when there is nothing
/// trustworthy to run.
@Suite("Fetched rules act only within the limits a signature does not widen")
struct FetchedRuleTests {

    @Test("A plain trash rule arrives ready to use")
    func trashRuleStaysActive() {
        let rule = RuleDefinition.fixture(root: anyRoot, action: .trash, grade: .safe)
        #expect(FetchedRulePolicy.clamp(rule).status == .active)
    }

    @Test("Anything beyond moving a user file to the Trash arrives detect-only")
    func widerRulesAreDemoted() {
        let beyondLimits: [(String, RuleDefinition)] = [
            ("runs a command", .fixture(root: anyRoot, action: .command(.brewCleanup))),
            ("needs admin rights", .fixture(root: anyRoot, privilege: .administrator)),
            ("evicts an iCloud copy", .fixture(root: anyRoot, action: .evictCloudCopy)),
            ("reveals only", .fixture(root: anyRoot, action: .revealOnly)),
            ("holds authored work", .fixture(root: anyRoot, holdsAuthoredWork: true)),
            ("is graded keep", .fixture(root: anyRoot, grade: .keep)),
        ]

        for (description, rule) in beyondLimits {
            // Demoted, not dropped: the row still shows its size and its
            // explanation, and offers no checkbox.
            #expect(
                FetchedRulePolicy.clamp(rule).status == .detectOnly,
                "a fetched rule that \(description) must not arrive active"
            )
        }
    }

    @Test("A fetched rule cannot strip the authored-work protection off a built-in one")
    func protectionIsStickyPerRuleID() throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let builtIn = RuleDefinition.fixture(
            id: "transcripts", root: harness.directory,
            grade: .checkFirst, holdsAuthoredWork: true
        )
        // The dangerous update: the same id, re-graded safe, flag quietly gone.
        let override = RuleDefinition.fixture(
            id: "transcripts", root: harness.directory,
            grade: .safe, holdsAuthoredWork: false
        )
        try harness.cache.store(try harness.signer.sign(payload(version: 1, rules: [override])))

        let rules = try harness.source(builtIn: [builtIn]).load()
        let loaded = try #require(rules.first { $0.id == "transcripts" })

        #expect(loaded.holdsAuthoredWork)
        #expect(loaded.status == .detectOnly)
    }

    @Test("Fetched rules merge over the compiled ones by id")
    func fetchedRulesMergeByID() throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let compiled = [
            RuleDefinition.fixture(id: "kept", root: harness.directory),
            RuleDefinition.fixture(id: "replaced", root: harness.directory, grade: .safe),
        ]
        let fetched = [
            RuleDefinition.fixture(id: "replaced", root: harness.directory, grade: .checkFirst),
            RuleDefinition.fixture(id: "added", root: harness.directory),
        ]
        try harness.cache.store(try harness.signer.sign(payload(version: 1, rules: fetched)))

        let rules = try harness.source(builtIn: compiled).load()
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })

        // A catalogue that omits a rule has not retired it. Retiring is said out
        // loud, with maxOSVersion or detectOnly, not achieved by leaving it out.
        #expect(byID["kept"] != nil)
        #expect(byID["replaced"]?.grade == .checkFirst)
        #expect(byID["added"] != nil)
        #expect(rules.count == 3)
    }

    @Test("With no catalogue, or an unreadable one, the compiled rules are used")
    func fallsBackToCompiledRules() throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let compiled = [RuleDefinition.fixture(id: "compiled", root: harness.directory)]

        #expect(try harness.source(builtIn: compiled).load().map(\.id) == ["compiled"])

        // A cache file somebody rewrote by hand is not a crash and not a rule
        // source — it is the same as having no cache.
        try Data("{".utf8).write(to: harness.cache.file)
        #expect(try harness.source(builtIn: compiled).load().map(\.id) == ["compiled"])
    }

    @Test("An unsigned cache file is ignored even though it parses")
    func unsignedCacheIsIgnored() throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        // Valid JSON, valid shape, no valid signature: the local-tampering case.
        let forged = SignedCatalogue(
            payload: try harness.signer
                .encodePayload(payload(version: 99, rules: [.fixture(id: "forged", root: harness.directory)]))
                .base64EncodedString(),
            signature: Data(repeating: 0, count: 64).base64EncodedString()
        )
        try harness.cache.store(forged)

        let compiled = [RuleDefinition.fixture(id: "compiled", root: harness.directory)]
        #expect(try harness.source(builtIn: compiled).load().map(\.id) == ["compiled"])
        #expect(harness.source(builtIn: compiled).provenance == nil)
    }

    @Test("A verified catalogue reports which version is running")
    func provenanceDescribesTheRunningCatalogue() throws {
        let harness = try UpdateHarness()
        defer { harness.destroy() }

        let published = Date(timeIntervalSince1970: 1_700_000_000)
        try harness.cache.store(try harness.signer.sign(
            CataloguePayload(
                formatVersion: 1, catalogueVersion: 12, published: published,
                rules: [.fixture(id: "one", root: harness.directory)]
            )
        ))

        let provenance = try #require(harness.source(builtIn: []).provenance)
        #expect(provenance.catalogueVersion == 12)
        #expect(provenance.ruleCount == 1)
        #expect(abs(provenance.published.timeIntervalSince(published)) < 1)
    }
}

// MARK: - Harness

private var anyRoot: URL {
    URL(fileURLWithPath: "/tmp/attic-definition-tests")
}

private func payload(version: Int, rules: [RuleDefinition]) -> CataloguePayload {
    CataloguePayload(
        formatVersion: CataloguePayload.supportedFormatVersion,
        catalogueVersion: version,
        published: Date(timeIntervalSince1970: 1_700_000_000),
        rules: rules
    )
}

/// A throwaway key pair, so the tests exercise real Ed25519 verification rather
/// than a stubbed-out notion of "signed".
private struct TestSigner {
    private let privateKey = Curve25519.Signing.PrivateKey()

    var verifier: CatalogueVerifier {
        CatalogueVerifier(base64Key: privateKey.publicKey.rawRepresentation.base64EncodedString())
    }

    func encodePayload(_ payload: CataloguePayload) throws -> Data {
        try CatalogueCoding.encoder.encode(payload)
    }

    func sign(_ payload: CataloguePayload) throws -> SignedCatalogue {
        let bytes = try encodePayload(payload)
        return SignedCatalogue(
            payload: bytes.base64EncodedString(),
            signature: try privateKey.signature(for: bytes).base64EncodedString()
        )
    }
}

private struct StubTransport: DefinitionTransport {
    let data: Data
    func data(from url: URL) async throws -> Data { data }
}

private struct FailingTransport: DefinitionTransport {
    struct Offline: Error {}
    func data(from url: URL) async throws -> Data { throw Offline() }
}

/// A cache in a temporary directory, so no test writes to the real Application
/// Support folder.
private struct UpdateHarness {
    let signer = TestSigner()
    let directory: URL
    let cache: DefinitionCache
    let feed = URL(string: "https://example.invalid/definitions.json")!

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "attic-definitions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = DefinitionCache(directory: directory)
    }

    func updater(serving document: SignedCatalogue) throws -> DefinitionUpdater {
        DefinitionUpdater(
            feed: feed,
            transport: StubTransport(data: try CatalogueCoding.encoder.encode(document)),
            verifier: signer.verifier,
            cache: cache
        )
    }

    func source(builtIn: [RuleDefinition]) -> RemoteDefinitionSource {
        RemoteDefinitionSource(cache: cache, verifier: signer.verifier, builtIn: builtIn)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }
}
