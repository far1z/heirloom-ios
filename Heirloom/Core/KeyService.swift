import Foundation
import BitcoinDevKit

/// Key generation and derivation. All secret material stays inside this process and
/// the Keychain; nothing here performs any network activity.
enum KeyService {
    /// Generate a fresh 12-word BIP-39 mnemonic using the platform CSPRNG (via BDK).
    static func generateMnemonic() -> Mnemonic {
        Mnemonic(wordCount: .words12)
    }

    static func parseMnemonic(_ words: String) throws -> Mnemonic {
        let normalized = words
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        guard let m = try? Mnemonic.fromString(mnemonic: normalized) else {
            throw HeirloomError.invalidMnemonic
        }
        return m
    }

    /// Account-level secret key at m/48'/<coin>'/0'/2' for the given seed.
    static func accountSecretKey(
        mnemonic: Mnemonic,
        network: AppNetwork
    ) throws -> DescriptorSecretKey {
        let master = DescriptorSecretKey(
            networkKind: network.bdkNetworkKind,
            mnemonic: mnemonic,
            password: nil
        )
        return try master.derive(path: InheritanceDescriptor.accountPath(network: network))
    }

    /// Account-level public key string (with key origin) for sharing with the other party.
    static func accountPublicKeyString(
        mnemonic: Mnemonic,
        network: AppNetwork
    ) throws -> String {
        try accountSecretKey(mnemonic: mnemonic, network: network).asPublic().description
    }

    /// Master fingerprint of a seed (for display/verification, e.g. "a1b2c3d4").
    static func masterFingerprint(
        mnemonic: Mnemonic,
        network: AppNetwork
    ) throws -> String {
        let master = DescriptorSecretKey(
            networkKind: network.bdkNetworkKind,
            mnemonic: mnemonic,
            password: nil
        )
        return master.asPublic().masterFingerprint()
    }

    // MARK: - Keychain-backed storage

    static func storeMnemonic(_ mnemonic: Mnemonic, as key: KeychainStore.Key) throws {
        guard let data = mnemonic.description.data(using: .utf8) else {
            throw HeirloomError.invalidMnemonic
        }
        try KeychainStore.save(data, for: key)
    }

    static func loadMnemonic(_ key: KeychainStore.Key) throws -> Mnemonic {
        let data = try KeychainStore.load(key)
        guard let words = String(data: data, encoding: .utf8) else {
            throw HeirloomError.invalidMnemonic
        }
        return try parseMnemonic(words)
    }
}
