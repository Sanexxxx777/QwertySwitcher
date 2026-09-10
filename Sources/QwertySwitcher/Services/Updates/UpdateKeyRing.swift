import Foundation
import CryptoKit

/// Embedded Ed25519 public keys for verifying `appcast.json`. Two keys live
/// here at once (`k1` = current, `k2` = next) so a future rotation can ship
/// a build that already trusts the new key before it's ever used to sign a
/// release — see `Scripts/release.sh [k1|k2]`. Private keys never appear in
/// this repo (`~/.claude/secrets/qsw_update_ed25519_<id>.key`, chmod 600).
enum UpdateKeyRing {
    /// keyId -> base64 raw Ed25519 public key (32-byte `rawRepresentation`).
    static let publicKeys: [String: String] = [
        "k1": "wNhEr2ENSrWFn3RSbBtRXV7/slD/YL+JU5P77oSZO8o=",
        "k2": "cFVUSlF/hHoGj1bUOnpFf/DgaFej5w/gmwlybG3YUNw=",
    ]

    enum KeyRingError: Error, Equatable { case unknownKeyId, malformedKey }

    static func publicKey(for keyId: String) throws -> Curve25519.Signing.PublicKey {
        guard let base64 = publicKeys[keyId] else { throw KeyRingError.unknownKeyId }
        guard let raw = Data(base64Encoded: base64) else { throw KeyRingError.malformedKey }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw KeyRingError.malformedKey
        }
        return key
    }
}
