import Foundation
import BitcoinDevKit

/// Builds the 2-key inheritance descriptor at the core of Heirloom.
///
/// Policy (Miniscript):
///
///     wsh(or_d(pk(OWNER), and_v(v:pk(HEIR), older(DELAY))))
///
/// Semantics enforced by the Bitcoin network itself:
///  - The OWNER key can spend at any time (first `or_d` branch).
///  - The HEIR key can spend **only** when the spending input's UTXO has at least
///    DELAY confirmations (BIP-68 relative timelock via `older`, i.e. OP_CSV),
///    and only with the heir's signature. The timelock is per-UTXO and restarts
///    every time the coins move — which is exactly what a "heartbeat" does.
///  - Nobody else can ever spend. There is no third key, no service key, and no
///    cooperation requirement. A "Pro" heartbeat service can only *remind* or
///    *request*; it can never move funds.
///
/// `or_d` was chosen over `or_i`/`or_c` because it puts the owner's key in the
/// "likely" branch (cheapest, satisfied with a single signature + empty dissatisfaction
/// for the backup branch) and is the canonical construction for a primary-key +
/// timelocked-recovery policy. The resulting script is standard, non-malleable, and
/// satisfiable under both consensus and standardness rules (`Descriptor.sanityCheck`
/// is asserted in tests).
///
/// Keys are BIP-32 extended keys derived from each party's own BIP-39 seed at
///
///     m/48'/<coin>'/0'/2'        (BIP-48, script type 2' = native segwit multisig-style)
///
/// and used in the descriptor as multipath expressions `KEY/<0;1>/*` so a single
/// descriptor yields both the external (receive) and internal (change) keychains.
enum InheritanceDescriptor {
    /// BIP-48 account-level derivation path for a given network.
    static func accountPath(network: AppNetwork) throws -> DerivationPath {
        try DerivationPath(path: "m/48h/\(network.coinType)h/0h/2h")
    }

    /// The multipath descriptor string, from one secret key (the side we can sign for)
    /// and one public key (the other party).
    ///
    /// - Parameters:
    ///   - signerKey: account-level `DescriptorSecretKey` (already derived to m/48'/.../2').
    ///   - otherKey: the counterparty's account-level public key string (with origin).
    ///   - signerIsOwner: whether `signerKey` occupies the owner slot.
    ///   - delayBlocks: CSV delay, 1...65535.
    static func descriptorString(
        signerKey: DescriptorSecretKey,
        otherKey: String,
        signerIsOwner: Bool,
        delayBlocks: UInt32
    ) throws -> String {
        guard DelayPreset.isValidCSV(delayBlocks) else {
            throw HeirloomError.invalidDelay(delayBlocks)
        }
        let signer = "\(signerKey)/<0;1>/*"
        let other = "\(otherKey)/<0;1>/*"
        let ownerExpr = signerIsOwner ? signer : other
        let heirExpr = signerIsOwner ? other : signer
        return "wsh(or_d(pk(\(ownerExpr)),and_v(v:pk(\(heirExpr)),older(\(delayBlocks)))))"
    }

    /// Watch-only variant built purely from two public keys.
    static func publicDescriptorString(
        ownerKey: String,
        heirKey: String,
        delayBlocks: UInt32
    ) throws -> String {
        guard DelayPreset.isValidCSV(delayBlocks) else {
            throw HeirloomError.invalidDelay(delayBlocks)
        }
        return "wsh(or_d(pk(\(ownerKey)/<0;1>/*),and_v(v:pk(\(heirKey)/<0;1>/*),older(\(delayBlocks)))))"
    }

    /// Parse + sanity-check a descriptor string into a BDK `Descriptor`.
    ///
    /// `sanityCheck()` verifies every spend path is possible under current consensus
    /// and standardness rules, that all paths require signatures, and that the script
    /// is non-malleable — the exact guarantees the inheritance design depends on.
    static func parse(_ descriptor: String, network: AppNetwork) throws -> Descriptor {
        let d = try Descriptor(descriptor: descriptor, networkKind: network.bdkNetworkKind)
        try d.sanityCheck()
        return d
    }
}
