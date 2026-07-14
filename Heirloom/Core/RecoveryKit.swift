import Foundation

/// The "Heir Recovery Kit" — everything an heir needs, *besides their own seed
/// phrase*, to reconstruct the inheritance wallet and claim funds after the
/// timelock expires.
///
/// Contains only public data: it cannot spend anything by itself and never
/// contains either party's seed. It is still privacy-sensitive (the keys reveal
/// wallet history to anyone who has it), so the UI tells owners to store it with
/// their estate documents, not to post it publicly.
struct RecoveryKit: Codable, Equatable {
    static let currentVersion = 1
    static let kitType = "heirloom-recovery-kit"

    var v: Int = RecoveryKit.currentVersion
    var type: String = RecoveryKit.kitType
    var network: AppNetwork
    var delayBlocks: UInt32
    /// Owner's account-level public key string (with origin).
    var ownerAccountKey: String
    /// Heir's account-level public key string, so the kit self-verifies against
    /// the seed the heir types in.
    var heirAccountKey: String
    /// Heir master fingerprint for a friendlier mismatch error.
    var heirFingerprint: String
    var createdAt: Date

    func encodeToJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(fromJSON json: String) throws -> RecoveryKit {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let kit = try? decoder.decode(RecoveryKit.self, from: data),
              kit.type == kitType else {
            throw HeirloomError.invalidMnemonic
        }
        guard DelayPreset.isValidCSV(kit.delayBlocks) else {
            throw HeirloomError.invalidDelay(kit.delayBlocks)
        }
        return kit
    }

    /// Human-readable document the owner prints/stores with estate papers.
    func humanReadableDocument() -> String {
        """
        ═══════════════════════════════════════════════
          HEIRLOOM — BITCOIN INHERITANCE RECOVERY KIT
        ═══════════════════════════════════════════════

        Give this document to your heir, together with
        their 12-word recovery phrase (on paper, stored
        separately). This document alone CANNOT move any
        funds — but keep it private: it reveals wallet
        balances to anyone who reads it.

        WHAT YOUR HEIR SHOULD DO
        1. Install the Heirloom app on an iPhone.
        2. Choose "I am an heir".
        3. Paste the kit code below when asked.
        4. Enter their own 12-word recovery phrase.
        5. The app shows a countdown. When it reaches
           zero, the app guides them through claiming
           the funds to their own wallet.

        The countdown restarts whenever the owner uses
        their wallet. If the owner is active, the heir
        cannot spend — that is the point of the design.

        KIT CODE (paste into the Heirloom app)
        ---------------------------------------------
        \((try? encodeToJSON()) ?? "ERROR ENCODING KIT")
        ---------------------------------------------

        Network: \(network.displayName)
        Inheritance delay: \(delayBlocks) blocks (~\(delayBlocks / 144) days)
        Created: \(ISO8601DateFormatter().string(from: createdAt))
        """
    }
}
