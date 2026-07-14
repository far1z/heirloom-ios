import Foundation
import BitcoinDevKit

/// Resolves BDK policy-path maps for the two spend paths of the inheritance descriptor.
///
/// BDK models `wsh(or_d(pk(owner), and_v(v:pk(heir), older(N))))` as a policy tree:
///
///     thresh(1) ─┬─ [0] ecdsaSignature(owner)
///                └─ [1] thresh(2) ─┬─ [0] ecdsaSignature(heir)
///                                  └─ [1] relativeTimelock(N)
///
/// When a descriptor has more than one way to be satisfied, BDK requires the caller
/// to pick a branch explicitly (`TxBuilder.policyPath`) so that transaction-level
/// parameters (here: the input's nSequence for the CSV branch) are set correctly.
/// We always pass an explicit path for both spend types — never rely on implicit
/// selection — so the transaction we build is exactly the one we mean to build.
enum PolicyPaths {
    struct Resolved {
        /// Path map selecting the owner (spend-anytime) branch.
        let owner: [String: [UInt64]]
        /// Path map selecting the heir (timelocked) branch.
        let heir: [String: [UInt64]]
        /// The CSV delay found in the timelock leaf, for cross-checking against config.
        let csvBlocks: UInt32?
    }

    /// Walk the wallet's spending policy for `keychain` and derive both path maps.
    static func resolve(wallet: Wallet, keychain: KeychainKind) throws -> Resolved {
        guard let root = try wallet.policies(keychain: keychain) else {
            throw HeirloomError.policyPathNotFound("root")
        }
        guard case let .thresh(items, threshold) = root.item(), threshold == 1, items.count == 2 else {
            throw HeirloomError.policyPathNotFound("or_d root")
        }

        var ownerIndex: UInt64?
        var heirIndex: UInt64?
        var heirPolicy: Policy?
        var csv: UInt32?

        for (i, child) in items.enumerated() {
            switch child.item() {
            case .ecdsaSignature:
                ownerIndex = UInt64(i)
            case let .thresh(subItems, subThreshold)
                where subThreshold == UInt64(subItems.count):
                // and_v(v:pk(heir), older(N)) — an n-of-n thresh of sig + timelock.
                var hasSig = false
                for sub in subItems {
                    switch sub.item() {
                    case .ecdsaSignature: hasSig = true
                    case .relativeTimelock(let value): csv = value
                    default: break
                    }
                }
                if hasSig, csv != nil {
                    heirIndex = UInt64(i)
                    heirPolicy = child
                }
            default:
                break
            }
        }

        guard let oIdx = ownerIndex else {
            throw HeirloomError.policyPathNotFound("owner signature branch")
        }
        guard let hIdx = heirIndex, let hPolicy = heirPolicy else {
            throw HeirloomError.policyPathNotFound("heir timelock branch")
        }

        let ownerPath: [String: [UInt64]] = [root.id(): [oIdx]]
        // For the heir path we must select the timelocked branch at the root AND
        // (explicitly, for clarity) both legs of the inner n-of-n thresh.
        let heirPath: [String: [UInt64]] = [
            root.id(): [hIdx],
            hPolicy.id(): [0, 1],
        ]
        return Resolved(owner: ownerPath, heir: heirPath, csvBlocks: csv)
    }
}
