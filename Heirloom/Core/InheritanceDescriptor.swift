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
/// and used in the descriptor as `KEY/0/*` (external/receive) and `KEY/1/*`
/// (internal/change).
///
/// Two separate single-path descriptors are used rather than one `<0;1>` multipath
/// expression: rust-miniscript cannot parse a multipath expression containing an
/// extended *private* key (it can't turn a multipath xprv into a pubkey), and the
/// signer side of this wallet always embeds its xprv.
enum InheritanceDescriptor {
    /// External (receive) and internal (change) descriptor strings.
    struct Pair: Equatable {
        let external: String
        let change: String
    }

    /// BIP-48 account-level derivation path for a given network.
    static func accountPath(network: AppNetwork) throws -> DerivationPath {
        try DerivationPath(path: "m/48h/\(network.coinType)h/0h/2h")
    }

    /// Descriptor strings from one secret key (the side we can sign for) and one
    /// public key (the other party).
    ///
    /// - Parameters:
    ///   - signerKey: account-level `DescriptorSecretKey` (already derived to m/48'/.../2').
    ///   - otherKey: the counterparty's account-level public key string (with origin).
    ///   - signerIsOwner: whether `signerKey` occupies the owner slot.
    ///   - delayBlocks: CSV delay, 1...65535.
    static func descriptorStrings(
        signerKey: DescriptorSecretKey,
        otherKey: String,
        signerIsOwner: Bool,
        delayBlocks: UInt32
    ) throws -> Pair {
        guard DelayPreset.isValidCSV(delayBlocks) else {
            throw HeirloomError.invalidDelay(delayBlocks)
        }
        func descriptor(path: Int) -> String {
            let signer = "\(signerKey)/\(path)/*"
            let other = "\(otherKey)/\(path)/*"
            let ownerExpr = signerIsOwner ? signer : other
            let heirExpr = signerIsOwner ? other : signer
            return "wsh(or_d(pk(\(ownerExpr)),and_v(v:pk(\(heirExpr)),older(\(delayBlocks)))))"
        }
        return Pair(external: descriptor(path: 0), change: descriptor(path: 1))
    }

    /// Watch-only variant built purely from two public keys.
    static func publicDescriptorStrings(
        ownerKey: String,
        heirKey: String,
        delayBlocks: UInt32
    ) throws -> Pair {
        guard DelayPreset.isValidCSV(delayBlocks) else {
            throw HeirloomError.invalidDelay(delayBlocks)
        }
        func descriptor(path: Int) -> String {
            "wsh(or_d(pk(\(ownerKey)/\(path)/*),and_v(v:pk(\(heirKey)/\(path)/*),older(\(delayBlocks)))))"
        }
        return Pair(external: descriptor(path: 0), change: descriptor(path: 1))
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
