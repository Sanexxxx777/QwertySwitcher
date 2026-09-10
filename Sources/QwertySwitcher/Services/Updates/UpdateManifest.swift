import Foundation

/// One release, as published inside `appcast.json`'s signed `manifestBase64`
/// payload. Field names match the JSON exactly — this struct is decoded
/// directly from the verified bytes, no re-canonicalization on this side
/// (see `UpdateManifestVerifier`: signature check happens on the raw bytes,
/// BEFORE they are ever handed to `JSONDecoder`).
struct UpdateManifest: Codable, Equatable {
    let version: String
    let build: Int
    let minSystemVersion: String
    let archiveURL: String
    let size: Int
    let sha256: String
    let publishedAt: String
    let validUntil: String
    let notes: String
}

/// The unsigned envelope fetched from the feed URL. `manifestBase64` decodes
/// to the exact bytes the signature in `signature` was computed over.
struct UpdateAppcast: Codable, Equatable {
    let keyId: String
    let manifestBase64: String
    let signature: String
}
