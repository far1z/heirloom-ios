import Foundation

/// Which side of the inheritance policy this device controls.
enum WalletRole: String, Codable {
    /// This device holds the owner seed and watches the heir's public key.
    case owner
    /// This device holds the heir seed and watches the owner's public key
    /// (heir recovery mode).
    case heir
}

/// Service tier chosen at setup. Pro is a client-side representation only for now:
/// it never has key material and can never move funds — see SECURITY_REVIEW.md.
enum ServiceTier: String, Codable {
    case free
    case pro
}

/// Non-secret wallet configuration. Seeds live exclusively in the Keychain
/// (`KeychainStore`); everything needed to *rebuild* the descriptor deterministically
/// — minus the local seed — lives here.
///
/// Stored via `WalletMetaStore` in Application Support with file protection
/// `.completeUntilFirstUserAuthentication` and excluded from iCloud backup.
/// Contents are privacy-sensitive (xpubs reveal balance history if leaked) but can
/// never spend funds.
struct WalletMeta: Codable, Equatable {
    var role: WalletRole
    var network: AppNetwork
    var delayBlocks: UInt32
    /// Account-level public key string (with origin) of the *other* party.
    var counterpartyKey: String
    /// Master fingerprint of the local seed, for display/sanity checks.
    var localFingerprint: String
    /// Account-level public key string (with origin) of the local seed.
    var localAccountKey: String
    var esploraURL: String
    var tier: ServiceTier
    var createdAt: Date

    /// Owner-side convenience: the heir's account public key.
    var heirAccountKey: String? {
        role == .owner ? counterpartyKey : localAccountKey
    }

    var ownerAccountKey: String? {
        role == .owner ? localAccountKey : counterpartyKey
    }
}

/// JSON persistence for `WalletMeta` in Application Support.
struct WalletMetaStore {
    static let filename = "wallet-meta.json"

    static var directory: URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Heirloom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent(filename) }

    static func save(_ meta: WalletMeta) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        excludeFromBackup(fileURL)
    }

    static func load() -> WalletMeta? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WalletMeta.self, from: data)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Wallet database (BDK SQLite) path, colocated with the metadata.
    static func walletDBPath(role: WalletRole) -> String {
        directory.appendingPathComponent("wallet-\(role.rawValue).sqlite").path
    }

    static func deleteWalletDBs() {
        for role in [WalletRole.owner, .heir] {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("wallet-\(role.rawValue).sqlite")
            )
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
