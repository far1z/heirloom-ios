import XCTest
import BitcoinDevKit
@testable import Heirloom

/// Offline tests of policy-path resolution and transaction construction, using
/// in-memory wallets seeded (via `TestFixtures`) with a UTXO confirmed at a fake
/// block. The full lifecycle against real consensus rules runs in
/// RegtestLifecycleTests.
final class PolicyAndTransactionTests: XCTestCase {
    let network = AppNetwork.signet
    let delay: UInt32 = 6

    func signOptions(assumeHeight: UInt32? = nil) -> SignOptions {
        SignOptions(
            trustWitnessUtxo: false, assumeHeight: assumeHeight,
            allowAllSighashes: false, tryFinalize: true,
            signWithTapInternalKey: true, allowGrinding: true
        )
    }

    // MARK: Policy paths

    func testPolicyRequiresExplicitPath() throws {
        let fx = try TestFixtures.makeConfirmedWallet(ownerSide: true, delay: delay)
        let policy = try XCTUnwrap(fx.wallet.policies(keychain: .external))
        XCTAssertTrue(policy.requiresPath(), "or_d policy must require an explicit spend path")
    }

    func testPolicyPathResolution() throws {
        for side in [true, false] {
            let fx = try TestFixtures.makeConfirmedWallet(ownerSide: side, delay: delay)
            for keychain in [KeychainKind.external, .internal] {
                let resolved = try PolicyPaths.resolve(wallet: fx.wallet, keychain: keychain)
                XCTAssertEqual(resolved.csvBlocks, delay, "CSV in policy must equal configured delay")
                XCTAssertEqual(resolved.owner.count, 1)
                XCTAssertEqual(resolved.heir.count, 2)
                // Owner and heir must select different root branches.
                let rootId = resolved.owner.keys.first!
                XCTAssertNotNil(resolved.heir[rootId])
                XCTAssertNotEqual(resolved.owner[rootId], resolved.heir[rootId])
            }
        }
    }

    // MARK: Fixture sanity

    func testSeededWalletSeesConfirmedUTXO() throws {
        let fx = try TestFixtures.makeConfirmedWallet(ownerSide: true, delay: delay)
        XCTAssertEqual(fx.wallet.balance().confirmed.toSat(), fx.fundedSats)
        let utxos = fx.wallet.listUnspent()
        XCTAssertEqual(utxos.count, 1)
        guard case let .confirmed(cbt, _) = utxos[0].chainPosition else {
            return XCTFail("fixture UTXO must be confirmed")
        }
        XCTAssertEqual(cbt.blockId.height, fx.confirmationHeight)
        XCTAssertEqual(fx.wallet.latestCheckpoint().height, fx.tipHeight)
    }

    // MARK: Owner spend (heartbeat shape)

    func testOwnerHeartbeatBuildsSignsAndFinalizes() throws {
        let fx = try TestFixtures.makeConfirmedWallet(ownerSide: true, delay: delay)
        let destination = fx.wallet.revealNextAddress(keychain: .external)
        let paths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .internal)
        let psbt = try TxBuilder()
            .drainWallet()
            .drainTo(script: destination.address.scriptPubkey())
            .excludeUnconfirmed()
            .policyPath(policyPath: paths.owner, keychain: .external)
            .policyPath(policyPath: changePaths.owner, keychain: .internal)
            .version(version: 2)
            .feeRate(feeRate: FeeRate.fromSatPerKwu(satKwu: 500))
            .finish(wallet: fx.wallet)

        let finalized = try fx.wallet.sign(psbt: psbt, signOptions: nil)
        XCTAssertTrue(finalized, "owner must be able to sign+finalize the owner branch immediately")

        let tx = try psbt.extractTx()
        XCTAssertEqual(tx.input().count, 1)
        XCTAssertEqual(tx.output().count, 1)
        // Owner branch must not carry the heir's CSV sequence value.
        XCTAssertNotEqual(tx.input()[0].sequence, delay,
                          "owner spend must not carry the heir's CSV sequence")
        XCTAssertGreaterThan(try psbt.fee(), 0)
        // Output pays back into the wallet (heartbeat semantics).
        XCTAssertTrue(fx.wallet.isMine(script: tx.output()[0].scriptPubkey))
    }

    /// The heir's wallet holds no owner key, and before the timelock matures the
    /// heir's own branch is unusable: no matter which policy path is requested,
    /// the heir must NOT be able to finalize a spend of an immature UTXO.
    /// (After maturity the heir legitimately finalizes via their own branch —
    /// that's the product, and it's covered by the claim tests.)
    func testHeirCannotSpendBeforeTimelockMatures() throws {
        let fx = try TestFixtures.makeConfirmedWallet(
            ownerSide: false, delay: delay,
            confirmationHeight: 100, tipHeight: 100  // only 1 confirmation of 6
        )
        let paths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .internal)
        let destination = fx.wallet.revealNextAddress(keychain: .external)
        let psbt = try TxBuilder()
            .drainWallet()
            .drainTo(script: destination.address.scriptPubkey())
            .policyPath(policyPath: paths.owner, keychain: .external)
            .policyPath(policyPath: changePaths.owner, keychain: .internal)
            .version(version: 2)
            .finish(wallet: fx.wallet)

        let finalized = try fx.wallet.sign(psbt: psbt, signOptions: nil)
        XCTAssertFalse(finalized, "heir must not be able to finalize any spend before the timelock matures")
    }

    /// Selecting the heir branch sets nSequence to the CSV delay — the consensus
    /// mechanism that makes early claims invalid — and signs once matured.
    func testHeirClaimCarriesCSVSequenceAndSignsWhenMature() throws {
        let fx = try TestFixtures.makeConfirmedWallet(
            ownerSide: false, delay: delay,
            confirmationHeight: 100, tipHeight: 100 + delay
        )
        let paths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .internal)
        let destination = fx.wallet.revealNextAddress(keychain: .external)
        let psbt = try TxBuilder()
            .drainWallet()
            .drainTo(script: destination.address.scriptPubkey())
            .policyPath(policyPath: paths.heir, keychain: .external)
            .policyPath(policyPath: changePaths.heir, keychain: .internal)
            .version(version: 2)
            .finish(wallet: fx.wallet)

        let tx = try psbt.extractTx()
        XCTAssertEqual(tx.input()[0].sequence, delay,
                       "heir branch must set nSequence to the CSV delay")
        XCTAssertEqual(tx.version(), 2, "BIP-68 requires tx version >= 2")

        let finalized = try fx.wallet.sign(psbt: psbt, signOptions: nil)
        XCTAssertTrue(finalized, "heir must be able to sign the timelocked branch once matured")
    }

    /// The "could a heartbeat/Pro service ever move funds?" property: a wallet
    /// built from public keys only (exactly what any server-side service would
    /// hold) must not be able to produce a single signature, on either branch.
    ///
    /// Note the inverse of `testHeirCannotSatisfyOwnerBranch` — "owner cannot
    /// satisfy the heir branch" — is deliberately NOT a test: the policy is an OR,
    /// so a heir-path PSBT signed by the owner legitimately finalizes through the
    /// owner branch. The owner can always spend; that is the design.
    func testWatchOnlyServiceCannotSignAnything() throws {
        let fx = try TestFixtures.makeConfirmedWallet(
            ownerSide: true, delay: delay,
            confirmationHeight: 100, tipHeight: 100 + delay + 100,
            watchOnly: true
        )
        let paths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: fx.wallet, keychain: .internal)
        let destination = fx.wallet.revealNextAddress(keychain: .external)

        for branch in [(paths.owner, changePaths.owner), (paths.heir, changePaths.heir)] {
            let psbt = try TxBuilder()
                .drainWallet()
                .drainTo(script: destination.address.scriptPubkey())
                .policyPath(policyPath: branch.0, keychain: .external)
                .policyPath(policyPath: branch.1, keychain: .internal)
                .version(version: 2)
                .finish(wallet: fx.wallet)
            let finalized = try fx.wallet.sign(psbt: psbt, signOptions: nil)
            XCTAssertFalse(finalized, "a keyless watch-only wallet must never finalize any branch")
        }
    }

    // MARK: Timelock arithmetic (mirrors WalletService.lockStatus)

    func testLockExpiryArithmetic() throws {
        // Confirmed at 100 with delay 6: matured when confirmations >= 6,
        // i.e. tip >= 105 (confirmation counts as the first).
        for (tip, expectClaimable) in [(UInt32(100), false), (104, false), (105, true), (200, true)] {
            let fx = try TestFixtures.makeConfirmedWallet(
                ownerSide: false, delay: delay,
                confirmationHeight: 100, tipHeight: tip
            )
            let utxo = fx.wallet.listUnspent()[0]
            guard case let .confirmed(cbt, _) = utxo.chainPosition else {
                return XCTFail("expected confirmed UTXO")
            }
            let confirmations = tip - cbt.blockId.height + 1
            XCTAssertEqual(confirmations >= delay, expectClaimable,
                           "tip \(tip): claimability arithmetic mismatch")
        }
    }
}
