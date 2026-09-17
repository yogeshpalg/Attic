import CryptoKit
import Foundation

/// The rules as they travel: a payload, and a signature over the exact bytes of
/// that payload.
///
/// The payload is carried base64-encoded rather than as a nested JSON object on
/// purpose. A signature covers bytes, and re-encoding a decoded object does not
/// reliably reproduce the bytes it was signed as — key order, whitespace and
/// date formatting all drift. Encoding the payload once, as an opaque string,
/// means the bytes verified are the bytes parsed.
struct SignedCatalogue: Codable, Sendable, Equatable {
    /// Base64 of the UTF-8 JSON of a `CataloguePayload`.
    let payload: String
    /// Base64 of the Ed25519 signature over the decoded payload bytes.
    let signature: String
}

/// What a signed catalogue actually says.
struct CataloguePayload: Codable, Sendable, Equatable {
    /// The shape of this document. An older app refuses a newer format outright
    /// rather than decoding half of it and guessing at the rest.
    let formatVersion: Int
    /// Monotonic. A catalogue older than the one already cached is refused, so
    /// serving an old file cannot roll back a correction.
    let catalogueVersion: Int
    let published: Date
    let rules: [RuleDefinition]

    /// The only format this build understands.
    static let supportedFormatVersion = 1
}

/// Why a catalogue was not believed.
///
/// Every case here ends the same way for the user: Attic keeps using the rules
/// compiled into the app. A definitions update that cannot be verified is not a
/// degraded update, it is no update.
enum DefinitionTrustError: Error, Equatable {
    /// No public key is compiled in, so nothing can be trusted yet.
    case noTrustedKey
    case malformedDocument
    case badSignature
    case unsupportedFormat(offered: Int, supported: Int)
    case downgrade(cached: Int, offered: Int)
}

/// Shared coding, so the bytes that are signed and the bytes that are parsed are
/// produced by the same rules on both sides.
enum CatalogueCoding {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// The public half of the signing key, base64-encoded.
///
/// Empty in this build, which means every fetched catalogue is refused with
/// `noTrustedKey` and Attic runs on its compiled rules. That is the correct
/// failure: an unset key must not mean "accept anything".
///
/// To generate the pair, run this once and keep the private key offline —
/// whoever holds it can ship rules to every copy of Attic:
///
///     let key = Curve25519.Signing.PrivateKey()
///     key.rawRepresentation.base64EncodedString()           // secret, offline
///     key.publicKey.rawRepresentation.base64EncodedString() // paste below
enum TrustedKeys {
    static let definitions = ""
}

/// Where updates are fetched from. `nil` until the repository exists, and the UI
/// offers no update button while it is nil — a button that cannot work is worse
/// than no button.
enum DefinitionFeed {
    static let url: URL? = nil
}

/// Checks a catalogue's signature and nothing else.
///
/// Verification is deliberately separate from fetching and from caching, because
/// it has to happen on both paths: bytes arriving from the network and bytes read
/// back off disk. The cache file sits in Application Support where the user — or
/// anything running as the user — can rewrite it, so a cached catalogue gets
/// exactly as much trust as a downloaded one, which is none until it verifies.
struct CatalogueVerifier: Sendable {

    private let publicKey: Curve25519.Signing.PublicKey?

    init(base64Key: String = TrustedKeys.definitions) {
        guard !base64Key.isEmpty,
              let raw = Data(base64Encoded: base64Key),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else {
            self.publicKey = nil
            return
        }
        self.publicKey = key
    }

    var hasTrustedKey: Bool { publicKey != nil }

    func verify(_ document: SignedCatalogue) throws -> CataloguePayload {
        guard let publicKey else { throw DefinitionTrustError.noTrustedKey }

        guard let payloadBytes = Data(base64Encoded: document.payload),
              let signature = Data(base64Encoded: document.signature)
        else { throw DefinitionTrustError.malformedDocument }

        guard publicKey.isValidSignature(signature, for: payloadBytes) else {
            throw DefinitionTrustError.badSignature
        }

        guard let payload = try? CatalogueCoding.decoder
            .decode(CataloguePayload.self, from: payloadBytes)
        else { throw DefinitionTrustError.malformedDocument }

        guard payload.formatVersion == CataloguePayload.supportedFormatVersion else {
            throw DefinitionTrustError.unsupportedFormat(
                offered: payload.formatVersion,
                supported: CataloguePayload.supportedFormatVersion
            )
        }

        return payload
    }
}
