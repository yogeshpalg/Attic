#!/usr/bin/env swift

// Signs a definitions catalogue for Attic.
//
//   swift Tools/sign-definitions.swift generate-key ~/.attic-signing/definitions.key
//   swift Tools/sign-definitions.swift sign catalogue.json ~/.attic-signing/definitions.key definitions.json
//   swift Tools/sign-definitions.swift verify definitions.json <public-key-base64>
//
// The private key never belongs in this repository. `generate-key` writes it
// outside the working tree with 0600 permissions and prints only the public
// half, which is what gets compiled into `TrustedKeys.definitions`.
//
// Whoever holds the private key can ship rules to every copy of Attic. Back it
// up somewhere you would put a password, and nowhere else.

import CryptoKit
import Foundation

// MARK: - Support

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The catalogue format this tool writes. Must match
/// `CataloguePayload.supportedFormatVersion` in the app.
let supportedFormatVersion = 1

/// Sanity checks before signing, so an obviously broken catalogue is caught
/// here rather than being refused silently by every copy of the app.
///
/// Deliberately light: the app is the authority on what a valid rule is, and a
/// second full validator here would be a second thing to keep in step.
func inspect(_ bytes: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        fail("that file is not a JSON object")
    }
    guard let format = object["formatVersion"] as? Int else {
        fail("no formatVersion")
    }
    guard format == supportedFormatVersion else {
        fail("formatVersion is \(format); this tool writes format \(supportedFormatVersion)")
    }
    guard let version = object["catalogueVersion"] as? Int, version > 0 else {
        fail("catalogueVersion must be a positive integer, and must go up with every publish")
    }
    guard let published = object["published"] as? String,
          ISO8601DateFormatter().date(from: published) != nil else {
        fail("published must be an ISO 8601 timestamp, e.g. 2026-09-17T00:00:00Z")
    }
    guard let rules = object["rules"] as? [[String: Any]], !rules.isEmpty else {
        fail("rules must be a non-empty array")
    }

    let ids = rules.compactMap { $0["id"] as? String }
    guard ids.count == rules.count else { fail("every rule needs an id") }
    guard Set(ids).count == ids.count else {
        let duplicates = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        fail("duplicate rule ids: \(duplicates.sorted().joined(separator: ", "))")
    }

    print("catalogue \(version), \(rules.count) rules, published \(published)")
}

// MARK: - Commands

func generateKey(at path: String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

    if FileManager.default.fileExists(atPath: url.path) {
        fail("\(url.path) already exists — refusing to overwrite a signing key")
    }

    let key = Curve25519.Signing.PrivateKey()
    let secret = key.rawRepresentation.base64EncodedString()

    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Written with 0600 from the start rather than chmod'ed after, so the
        // key is never briefly readable by anything else on the machine.
        try Data(secret.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    } catch {
        fail("could not write the key: \(error.localizedDescription)")
    }

    print("private key written to \(url.path) (0600) — back this up, it cannot be recovered")
    print("")
    print("public key, for TrustedKeys.definitions:")
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

func sign(payloadPath: String, keyPath: String, outputPath: String) {
    let payloadURL = URL(fileURLWithPath: (payloadPath as NSString).expandingTildeInPath)
    let keyURL = URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath)
    let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)

    guard let bytes = try? Data(contentsOf: payloadURL) else {
        fail("could not read \(payloadURL.path)")
    }
    inspect(bytes)

    guard let secret = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: secret.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("could not read a signing key from \(keyURL.path)")
    }

    guard let signature = try? key.signature(for: bytes) else {
        fail("signing failed")
    }

    // The payload is carried as base64 of the *original bytes*, never
    // re-encoded. A signature covers bytes, and re-encoding a decoded object
    // does not reliably reproduce them — key order, whitespace and date
    // formatting all drift. This keeps "the bytes verified" and "the bytes
    // parsed" the same bytes.
    let document: [String: String] = [
        "payload": bytes.base64EncodedString(),
        "signature": signature.base64EncodedString(),
    ]

    guard let encoded = try? JSONSerialization.data(
        withJSONObject: document, options: [.prettyPrinted, .sortedKeys]
    ) else {
        fail("could not encode the signed catalogue")
    }

    do {
        try encoded.write(to: outputURL, options: .atomic)
    } catch {
        fail("could not write \(outputURL.path): \(error.localizedDescription)")
    }

    print("signed → \(outputURL.path)")
    print("public key of the key used:")
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

/// Checks a signed catalogue the way the app will, so a publish can be verified
/// before it is uploaded rather than after somebody reports it refused.
func verify(documentPath: String, publicKeyBase64: String) {
    let url = URL(fileURLWithPath: (documentPath as NSString).expandingTildeInPath)

    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payloadBase64 = object["payload"] as? String,
          let signatureBase64 = object["signature"] as? String,
          let payload = Data(base64Encoded: payloadBase64),
          let signature = Data(base64Encoded: signatureBase64) else {
        fail("\(url.path) is not a signed catalogue")
    }

    guard let raw = Data(base64Encoded: publicKeyBase64),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("that is not a valid public key")
    }

    guard key.isValidSignature(signature, for: payload) else {
        fail("the signature does not match that key — Attic would refuse this catalogue")
    }

    inspect(payload)
    print("signature is valid")
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "generate-key":
    guard arguments.count == 2 else {
        fail("usage: generate-key <path for the private key>")
    }
    generateKey(at: arguments[1])

case "sign":
    guard arguments.count == 4 else {
        fail("usage: sign <catalogue.json> <private-key-file> <output.json>")
    }
    sign(payloadPath: arguments[1], keyPath: arguments[2], outputPath: arguments[3])

case "verify":
    guard arguments.count == 3 else {
        fail("usage: verify <signed.json> <public-key-base64>")
    }
    verify(documentPath: arguments[1], publicKeyBase64: arguments[2])

default:
    print("""
    Signs a definitions catalogue for Attic.

      generate-key <path>                             a new Ed25519 pair
      sign <catalogue.json> <key-file> <output.json>  sign a catalogue
      verify <signed.json> <public-key-base64>        check one before publishing

    The catalogue to sign is a JSON object:

      { "formatVersion": 1,
        "catalogueVersion": 2,
        "published": "2026-09-17T00:00:00Z",
        "rules": [ ... ] }

    Export a starting point from Attic: About Attic → Export template…
    """)
}
