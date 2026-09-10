#!/usr/bin/env swift
// Qwerty Switcher update-feed signing tool. Ed25519 (CryptoKit).
//
// Usage:
//   swift Scripts/sign-update.swift keygen [--out-private <path>] [--out-public <path>]
//   swift Scripts/sign-update.swift sign --key <private-key-path> --key-id <k1|k2> \
//       --manifest <manifest.json> --out <appcast.json>
//   swift Scripts/sign-update.swift verify --public <base64-public-key> --appcast <appcast.json>
//
// `sign` treats the manifest file's bytes AS THE CANONICAL BYTES — whatever
// is on disk at --manifest is exactly what gets base64'd and signed, with no
// re-serialization. The app verifies the signature over those same raw
// bytes before ever decoding them as JSON (see UpdateManifestVerifier).
import Foundation
import CryptoKit

struct AppcastEnvelope: Codable {
    let keyId: String
    let manifestBase64: String
    let signature: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readArg(_ name: String, _ args: [String]) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: sign-update.swift <keygen|sign|verify> [...]")
}
let rest = Array(arguments.dropFirst())

switch command {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    let privateB64 = key.rawRepresentation.base64EncodedString()
    let publicB64 = key.publicKey.rawRepresentation.base64EncodedString()

    if let outPrivate = readArg("--out-private", rest) {
        do {
            try (privateB64 + "\n").write(toFile: outPrivate, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outPrivate)
        } catch {
            fail("could not write private key to \(outPrivate): \(error)")
        }
    } else {
        print("private: \(privateB64)")
    }
    if let outPublic = readArg("--out-public", rest) {
        try? (publicB64 + "\n").write(toFile: outPublic, atomically: true, encoding: .utf8)
    }
    print("public: \(publicB64)")

case "sign":
    guard let keyPath = readArg("--key", rest),
          let keyId = readArg("--key-id", rest),
          let manifestPath = readArg("--manifest", rest),
          let outPath = readArg("--out", rest)
    else {
        fail("usage: sign-update.swift sign --key <path> --key-id <id> --manifest <json> --out <appcast.json>")
    }
    guard let keyLine = try? String(contentsOfFile: keyPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let rawKey = Data(base64Encoded: keyLine),
        let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    else {
        fail("could not read a valid Ed25519 private key (base64 of 32 raw bytes) from \(keyPath)")
    }
    guard let manifestBytes = FileManager.default.contents(atPath: manifestPath) else {
        fail("could not read manifest at \(manifestPath)")
    }
    guard let signature = try? privateKey.signature(for: manifestBytes) else {
        fail("signing failed")
    }
    let envelope = AppcastEnvelope(
        keyId: keyId,
        manifestBase64: manifestBytes.base64EncodedString(),
        signature: signature.base64EncodedString()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let out = try? encoder.encode(envelope) else { fail("could not encode appcast JSON") }
    do {
        try out.write(to: URL(fileURLWithPath: outPath))
    } catch {
        fail("could not write \(outPath): \(error)")
    }
    print("wrote \(outPath) (keyId=\(keyId), \(manifestBytes.count) manifest bytes)")

case "verify":
    guard let publicB64 = readArg("--public", rest),
          let appcastPath = readArg("--appcast", rest)
    else {
        fail("usage: sign-update.swift verify --public <base64> --appcast <file>")
    }
    guard let rawPublic = Data(base64Encoded: publicB64),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublic)
    else {
        fail("bad public key (expected base64 of 32 raw bytes)")
    }
    guard let data = FileManager.default.contents(atPath: appcastPath),
          let envelope = try? JSONDecoder().decode(AppcastEnvelope.self, from: data)
    else {
        fail("could not read/parse appcast at \(appcastPath)")
    }
    guard let manifestBytes = Data(base64Encoded: envelope.manifestBase64),
          let signatureBytes = Data(base64Encoded: envelope.signature)
    else {
        fail("appcast has malformed base64 fields")
    }
    guard publicKey.isValidSignature(signatureBytes, for: manifestBytes) else {
        fail("signature verification FAILED")
    }
    print("OK: signature verified (\(manifestBytes.count) manifest bytes, keyId=\(envelope.keyId))")

default:
    fail("unknown command: \(command)")
}
