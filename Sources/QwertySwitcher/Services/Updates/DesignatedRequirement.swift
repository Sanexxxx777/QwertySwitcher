import Foundation

/// Pure reduction of a bundle's Designated Requirement string down to what
/// tccd actually matches on — mirrors `signing_identity_of()` in
/// `Scripts/install.sh` byte for byte (that script's header comment explains
/// WHY: the stored TCC csreq names the signing identity, not the CDHash).
enum DesignatedRequirement {
    /// "unsigned" — no signature at all.
    /// "adhoc"    — cdhash-based DR (ad-hoc signature); changes every rebuild.
    /// otherwise  — the identity-bearing DR string, compared verbatim.
    static func signingIdentity(fromDesignatedRequirement dr: String?) -> String {
        guard let dr, !dr.isEmpty else { return "unsigned" }
        if dr.contains("cdhash") { return "adhoc" }
        return dr
    }
}
