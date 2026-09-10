import Foundation
import CryptoKit

/// Verifies an `UpdateAppcast` and decodes its manifest. Order matters: the
/// raw bytes are signature-checked BEFORE any JSON decoding touches them —
/// decoding untrusted bytes first would let a malformed-but-plausible
/// manifest reach application logic before its authenticity is known.
enum UpdateManifestVerifier {
    enum VerificationError: Error, Equatable {
        case malformedManifestBase64
        case malformedSignature
        case unknownKeyId
        case malformedKey
        case badSignature
        case malformedManifestJSON
    }

    static func verify(_ appcast: UpdateAppcast) -> Result<UpdateManifest, VerificationError> {
        guard let manifestBytes = Data(base64Encoded: appcast.manifestBase64) else {
            return .failure(.malformedManifestBase64)
        }
        guard let signatureBytes = Data(base64Encoded: appcast.signature) else {
            return .failure(.malformedSignature)
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try UpdateKeyRing.publicKey(for: appcast.keyId)
        } catch UpdateKeyRing.KeyRingError.unknownKeyId {
            return .failure(.unknownKeyId)
        } catch {
            return .failure(.malformedKey)
        }

        guard publicKey.isValidSignature(signatureBytes, for: manifestBytes) else {
            return .failure(.badSignature)
        }
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestBytes) else {
            return .failure(.malformedManifestJSON)
        }
        return .success(manifest)
    }
}
