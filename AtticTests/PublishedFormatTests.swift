import Foundation
import Testing

@testable import Attic

/// The publishing chain, checked against the shipping build.
///
/// Every other test in this file's neighbourhood generates its own throwaway
/// key, which proves the verification logic but proves nothing about the key
/// compiled into *this* binary or the bytes `Tools/sign-definitions.swift`
/// actually produces. This suite closes that gap with one catalogue, signed by
/// the real key, checked by the real verifier.
///
/// It is a tripwire in three directions:
///
/// - rotate the signing key without updating `TrustedKeys` and this fails
/// - change how a rule encodes and this fails, because the published bytes
///   would no longer decode
/// - ship with an empty key and this fails, rather than the update feature
///   silently doing nothing
@Suite("A catalogue signed by the real key is accepted by this build")
struct PublishedFormatTests {

    /// Produced by `swift Tools/sign-definitions.swift sign`, from
    /// `Tools/definitions/sample-catalogue.json`. Inlined rather than read from
    /// disk so the test does not depend on a bundled resource or a repo path.
    private static let payload = """
        ewogICJmb3JtYXRWZXJzaW9uIjogMSwKICAiY2F0YWxvZ3VlVmVyc2lvbiI6IDIsCiAgInB1Ymxpc2hl\
        ZCI6ICIyMDI2LTA5LTE3VDAwOjAwOjAwWiIsCiAgInJ1bGVzIjogWwogICAgewogICAgICAiaWQiOiAi\
        Y2FjaGVzLmV4YW1wbGUiLAogICAgICAibWluQXBwVmVyc2lvbiI6ICIxLjAiLAogICAgICAiY2F0ZWdv\
        cnkiOiAiY2FjaGVzQW5kTG9ncyIsCiAgICAgICJkaXNwbGF5TmFtZSI6ICJFeGFtcGxlIHRvb2wgY2Fj\
        aGUiLAogICAgICAicm9vdCI6IHsgImhvbWUiOiB7ICJfMCI6ICJMaWJyYXJ5L0NhY2hlcy9jb20uZXhh\
        bXBsZS50b29sIiB9IH0sCiAgICAgICJtYXRjaCI6IHsgIndob2xlUm9vdCI6IHt9IH0sCiAgICAgICJl\
        eGNsdWRlIjogW10sCiAgICAgICJncm91cGluZyI6ICJzaW5nbGUiLAogICAgICAicmV0ZW50aW9uIjog\
        eyAibm9uZSI6IHt9IH0sCiAgICAgICJzdWJ0aXRsZVN0eWxlIjogImZpbGVDb3VudCIsCiAgICAgICJh\
        cHBsaWNhYmlsaXR5IjogeyAicm9vdEV4aXN0cyI6IHt9IH0sCiAgICAgICJhY3Rpb24iOiB7ICJ0cmFz\
        aCI6IHt9IH0sCiAgICAgICJwcml2aWxlZ2UiOiAidXNlciIsCiAgICAgICJncmFkZSI6ICJzYWZlIiwK\
        ICAgICAgImhvbGRzQXV0aG9yZWRXb3JrIjogZmFsc2UsCiAgICAgICJzdGF0dXMiOiAiYWN0aXZlIiwK\
        ICAgICAgImV4cGxhbmF0aW9uIjogewogICAgICAgICJ3aGF0VGhpc0lzIjogIkEgY2FjaGUgYW4gZXhh\
        bXBsZSB0b29sIHdyaXRlcy4iLAogICAgICAgICJ3aGF0U3RvcHNXb3JraW5nIjogIk5vdGhpbmcuIEl0\
        IGlzIHJlYnVpbHQgb24gbmV4dCB1c2UuIiwKICAgICAgICAiZG9lc0l0Q29tZUJhY2siOiAiWWVzLCB0\
        aGUgbmV4dCB0aW1lIHRoZSB0b29sIHJ1bnMuIgogICAgICB9CiAgICB9CiAgXQp9Cg==
        """

    private static let signature = """
        66iM3gika0e/6hThpLvzTd4Gl3qFCEJqatX6b372sHAynC/fJ6PxEcbgZgKpCvQtSGne4frCHBr2lUvb\
        Y4z6DA==
        """

    private var document: SignedCatalogue {
        SignedCatalogue(
            payload: Self.payload.replacingOccurrences(of: "\n", with: ""),
            signature: Self.signature.replacingOccurrences(of: "\n", with: "")
        )
    }

    @Test("This build carries a signing key")
    func buildHasATrustedKey() {
        // Without this, the whole update mechanism is inert and every other
        // assertion here would pass for the wrong reason.
        #expect(CatalogueVerifier().hasTrustedKey)
    }

    @Test("The shipping verifier accepts a catalogue from the real key")
    func realKeyVerifies() throws {
        let payload = try CatalogueVerifier().verify(document)

        #expect(payload.formatVersion == CataloguePayload.supportedFormatVersion)
        #expect(payload.catalogueVersion == 2)
        #expect(payload.rules.count == 1)
    }

    @Test("The rule inside decodes to the thing the file describes")
    func ruleDecodesFaithfully() throws {
        let rule = try #require(try CatalogueVerifier().verify(document).rules.first)

        // The published encoding of every associated-value enum: a wrong guess
        // about any one of these would mean a catalogue that signs cleanly and
        // then fails to parse on every Mac.
        #expect(rule.id == "caches.example")
        #expect(rule.root == .home("Library/Caches/com.example.tool"))
        #expect(rule.match == .wholeRoot)
        #expect(rule.retention == .none)
        #expect(rule.applicability == .rootExists)
        #expect(rule.action == .trash)
        #expect(rule.grade == .safe)
        #expect(rule.status == .active)
        #expect(rule.holdsAuthoredWork == false)
        #expect(rule.architecture == nil)
    }

    @Test("A signed rule still arrives inside the fetched limits")
    func signedRuleIsStillClamped() throws {
        let rule = try #require(try CatalogueVerifier().verify(document).rules.first)

        // Signed by the real key and still only as powerful as the policy
        // allows. This one is trash/user/safe, so it stays active.
        #expect(FetchedRulePolicy.isWithinFetchedLimits(rule))
        #expect(FetchedRulePolicy.clamp(rule).status == .active)
    }

    @Test("One flipped byte in the payload is refused by the real key")
    func tamperedPublishedCatalogueIsRefused() throws {
        var bytes = try #require(Data(base64Encoded: document.payload))
        bytes[bytes.count / 2] ^= 0x01

        let tampered = SignedCatalogue(
            payload: bytes.base64EncodedString(), signature: document.signature
        )

        #expect(throws: DefinitionTrustError.badSignature) {
            try CatalogueVerifier().verify(tampered)
        }
    }
}
