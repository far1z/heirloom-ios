import XCTest
import BitcoinDevKit
@testable import Heirloom

/// Full inheritance-lifecycle integration test against a REAL Bitcoin node
/// (regtest) and a real Electrum server, exercising actual consensus rules:
///
///   fund → countdown → heartbeat resets clock → early claim REJECTED by the
///   node (BIP-68 "non-BIP68-final") → timelock expires → heir claims → funds move.
///
/// Start the stack first: `./scripts/regtest-up.sh` (bitcoind :18443, electrs
/// :60401). When the stack isn't running, every test here skips, so the default
/// `xcodebuild test` run stays green without local infrastructure.
final class RegtestLifecycleTests: XCTestCase {
    static let electrumURL = "tcp://127.0.0.1:60401"
    static let rpcURL = URL(string: "http://127.0.0.1:18443")!
    static let rpcAuth = "Basic " + Data("heirloom:heirloom".utf8).base64EncodedString()

    /// Short CSV delay: long enough to observe every intermediate state.
    let delay: UInt32 = 5
    let fundSats: UInt64 = 1_000_000

    override func setUpWithError() throws {
        try XCTSkipUnless(stackIsUp(), "regtest stack not running — start with scripts/regtest-up.sh")
    }

    // MARK: - JSON-RPC plumbing

    struct RPCError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    @discardableResult
    func rpc(_ method: String, _ params: [Any] = [], wallet: String? = nil) throws -> Any {
        var url = Self.rpcURL
        if let wallet { url = url.appendingPathComponent("wallet/\(wallet)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.rpcAuth, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "1.0", "id": "heirloom-test", "method": method, "params": params,
        ])
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Any, Error> = .failure(RPCError(message: "no response"))
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(RPCError(message: "bad response")); return
            }
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                result = .failure(RPCError(message: msg)); return
            }
            result = .success(json["result"] ?? NSNull())
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    func stackIsUp() -> Bool {
        (try? rpc("getblockchaininfo")) != nil
    }

    func minerAddress() throws -> String {
        try XCTUnwrap(rpc("getnewaddress", [], wallet: "miner") as? String)
    }

    func mine(_ blocks: Int) throws {
        _ = try rpc("generatetoaddress", [blocks, try minerAddress()], wallet: "miner")
    }

    func tipHeight() throws -> UInt32 {
        let info = try XCTUnwrap(rpc("getblockchaininfo") as? [String: Any])
        return UInt32(try XCTUnwrap(info["blocks"] as? Int))
    }

    // MARK: - Helpers

    func makeServices() throws -> (owner: WalletService, heir: WalletService) {
        let network = AppNetwork.regtest
        let ownerMnemonic = try KeyService.parseMnemonic(TestSeeds.ownerWords)
        let heirMnemonic = try KeyService.parseMnemonic(TestSeeds.heirWords)
        try KeyService.storeMnemonic(ownerMnemonic, as: .ownerMnemonic)
        try KeyService.storeMnemonic(heirMnemonic, as: .heirMnemonic)

        let ownerPub = try KeyService.accountPublicKeyString(mnemonic: ownerMnemonic, network: network)
        let heirPub = try KeyService.accountPublicKeyString(mnemonic: heirMnemonic, network: network)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("heirloom-regtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let ownerMeta = WalletMeta(
            role: .owner, network: network, delayBlocks: delay,
            counterpartyKey: heirPub,
            localFingerprint: try KeyService.masterFingerprint(mnemonic: ownerMnemonic, network: network),
            localAccountKey: ownerPub,
            esploraURL: Self.electrumURL, tier: .free, createdAt: Date()
        )
        let heirMeta = WalletMeta(
            role: .heir, network: network, delayBlocks: delay,
            counterpartyKey: ownerPub,
            localFingerprint: try KeyService.masterFingerprint(mnemonic: heirMnemonic, network: network),
            localAccountKey: heirPub,
            esploraURL: Self.electrumURL, tier: .free, createdAt: Date()
        )
        let owner = try WalletService(meta: ownerMeta, dbPath: tmp.appendingPathComponent("owner.sqlite").path)
        let heir = try WalletService(meta: heirMeta, dbPath: tmp.appendingPathComponent("heir.sqlite").path)
        return (owner, heir)
    }

    /// Poll `sync`/`fullScan` until `condition` is true (electrs indexing lags
    /// block production by a moment).
    func waitForSync(
        _ service: WalletService,
        fullScan: Bool = false,
        timeout: TimeInterval = 30,
        condition: (WalletService) -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fullScan { try service.fullScan() } else { try service.sync() }
            if condition(service) { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTFail("timed out waiting for wallet sync condition")
    }

    // MARK: - The lifecycle

    func testFullInheritanceLifecycle() throws {
        let services = try makeServices()
        let owner = services.owner
        let heir = services.heir

        // ── 1. Fund the inheritance wallet ────────────────────────────────
        let fundAddress = try owner.nextReceiveAddress().address.description
        XCTAssertTrue(fundAddress.hasPrefix("bcrt1q"), "P2WSH regtest address expected")
        _ = try rpc("sendtoaddress", [fundAddress, 0.01], wallet: "miner")
        try mine(1)
        let fundHeight = try tipHeight()

        try waitForSync(owner) { $0.balance().confirmed.toSat() == self.fundSats }
        var status = owner.lockStatus()
        XCTAssertEqual(status.tipHeight, fundHeight)
        XCTAssertEqual(status.earliestExpiryHeight, fundHeight + delay - 1)
        XCTAssertEqual(status.blocksRemaining, delay - 1)
        XCTAssertFalse(status.heirCanClaim)

        // Heir's device discovers the same funds via full scan.
        try waitForSync(heir, fullScan: true) { $0.balance().confirmed.toSat() == self.fundSats }
        XCTAssertFalse(heir.lockStatus().heirCanClaim)

        // ── 2. Premature claim is refused by our own guard ────────────────
        let heirPayout = try minerAddress()
        XCTAssertThrowsError(try heir.prepareHeirClaim(toAddress: heirPayout, feeRate: 2)) { error in
            guard case HeirloomError.timelockNotExpired(let remaining) = error else {
                return XCTFail("expected timelockNotExpired, got \(error)")
            }
            XCTAssertEqual(remaining, self.delay - 1)
        }

        // ── 3. Heartbeat resets the clock ─────────────────────────────────
        let beforeExpiry = try XCTUnwrap(status.earliestExpiryHeight)
        let heartbeat = try owner.prepareHeartbeat(feeRate: 2)
        XCTAssertGreaterThan(heartbeat.feeSats, 0)
        let heartbeatTxid = try owner.broadcast(heartbeat)
        try mine(1)
        let heartbeatHeight = try tipHeight()

        try waitForSync(owner) { service in
            if case .some(let expiry) = service.lockStatus().earliestExpiryHeight {
                return expiry == heartbeatHeight + self.delay - 1
            }
            return false
        }
        status = owner.lockStatus()
        XCTAssertGreaterThan(try XCTUnwrap(status.earliestExpiryHeight), beforeExpiry,
                             "heartbeat must push the expiry outward")
        XCTAssertEqual(status.blocksRemaining, delay - 1)
        // Balance shrank only by the fee.
        XCTAssertEqual(owner.balance().confirmed.toSat(), fundSats - heartbeat.feeSats)

        // ── 4. Node rejects an early claim (BIP-68, real consensus) ───────
        // Advance to one block BEFORE maturity, then broadcast a fully-signed
        // claim with the correct CSV sequence. bitcoind must reject it.
        try mine(Int(delay) - 2) // confirmations of heartbeat output: delay - 1
        try waitForSync(heir, fullScan: true) { $0.tipHeight() == heartbeatHeight + self.delay - 2 }

        let earlyClaim = try buildRawHeirClaim(payTo: heirPayout)
        XCTAssertThrowsError(
            try rpc("sendrawtransaction", [earlyClaim]),
            "consensus must reject a CSV spend one block early"
        ) { error in
            XCTAssertTrue("\(error)".contains("non-BIP68-final"),
                          "expected non-BIP68-final, got: \(error)")
        }

        // Our own service-level guard agrees.
        XCTAssertThrowsError(try heir.prepareHeirClaim(toAddress: heirPayout, feeRate: 2)) { error in
            guard case HeirloomError.timelockNotExpired(let remaining) = error else {
                return XCTFail("expected timelockNotExpired, got \(error)")
            }
            XCTAssertEqual(remaining, 1)
        }

        // ── 5. Timelock expires; heir claims through the app path ─────────
        try mine(1)
        try waitForSync(heir, fullScan: true) { $0.lockStatus().heirCanClaim }

        let claim = try heir.prepareHeirClaim(toAddress: heirPayout, feeRate: 2)
        XCTAssertGreaterThan(claim.feeSats, 0)
        let claimTxid = try heir.broadcast(claim) // Electrum broadcast = node accepted it
        XCTAssertFalse(claimTxid.isEmpty)
        try mine(1)

        // ── 6. Funds actually moved ───────────────────────────────────────
        try waitForSync(heir, fullScan: true) { $0.balance().total.toSat() == 0 }
        try waitForSync(owner) { $0.balance().total.toSat() == 0 }

        let received = try XCTUnwrap(rpc("getreceivedbyaddress", [heirPayout, 1], wallet: "miner") as? Double)
        let expected = Double(fundSats - heartbeat.feeSats - claim.feeSats) / 100_000_000
        XCTAssertEqual(received, expected, accuracy: 1e-9,
                       "heir payout address must hold funded amount minus the two fees")

        print("REGTEST LIFECYCLE EVIDENCE: funded=\(fundSats)sats heartbeat=\(heartbeatTxid) claim=\(claimTxid) receivedBTC=\(received)")
    }

    /// Build a fully-signed heir claim directly with BDK (bypassing the app's
    /// maturity guard) so the *node* gets to veto it. Uses a parallel wallet on
    /// the same descriptors.
    private func buildRawHeirClaim(payTo address: String) throws -> String {
        let network = AppNetwork.regtest
        let ownerMnemonic = try KeyService.parseMnemonic(TestSeeds.ownerWords)
        let heirMnemonic = try KeyService.parseMnemonic(TestSeeds.heirWords)
        let signer = try KeyService.accountSecretKey(mnemonic: heirMnemonic, network: network)
        let ownerPub = try KeyService.accountPublicKeyString(mnemonic: ownerMnemonic, network: network)
        let pair = try InheritanceDescriptor.descriptorStrings(
            signerKey: signer, otherKey: ownerPub, signerIsOwner: false, delayBlocks: delay
        )
        let wallet = try Wallet(
            descriptor: try InheritanceDescriptor.parse(pair.external, network: network),
            changeDescriptor: try InheritanceDescriptor.parse(pair.change, network: network),
            network: network.bdkNetwork,
            persister: try Persister.newInMemory()
        )
        let client = try ElectrumClient(url: Self.electrumURL)
        let scan = try wallet.startFullScan().build()
        try wallet.applyUpdate(update: client.fullScan(request: scan, stopGap: 20, batchSize: 10, fetchPrevTxouts: true))

        let dest = try Address(address: address, network: network.bdkNetwork)
        let paths = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: wallet, keychain: .internal)
        let psbt = try TxBuilder()
            .drainWallet()
            .drainTo(script: dest.scriptPubkey())
            .policyPath(policyPath: paths.heir, keychain: .external)
            .policyPath(policyPath: changePaths.heir, keychain: .internal)
            .version(version: 2)
            .feeRate(feeRate: FeeRate.fromSatPerKwu(satKwu: 500))
            .finish(wallet: wallet)
        let finalized = try wallet.sign(
            psbt: psbt,
            signOptions: SignOptions(
                trustWitnessUtxo: false, assumeHeight: try tipHeight() + 10_000,
                allowAllSighashes: false, tryFinalize: true,
                signWithTapInternalKey: true, allowGrinding: true
            )
        )
        XCTAssertTrue(finalized, "raw claim must sign (validity is the node's call)")
        let tx = try psbt.extractTx()
        return tx.serialize().map { String(format: "%02x", $0) }.joined()
    }
}
