import XCTest
import BitcoinDevKit
@testable import Heirloom

/// PUBLIC-NETWORK lifecycle test on Mutinynet — a public Bitcoin signet with
/// 30-second blocks and a captcha-free faucet — producing publicly auditable
/// evidence (txids viewable at https://mutinynet.com).
///
/// Opt-in because it depends on third-party infrastructure and takes minutes.
/// Enable by creating a marker file on the host (the simulator shares the
/// host filesystem):
///
///   touch /tmp/heirloom-signet-optin
///   xcodebuild test ... -only-testing:HeirloomTests/SignetLifecycleTests
///
/// Fresh random seeds are generated per run (the repo's fixed test seeds are
/// public, so they must never hold funds on a public network, even test sats).
final class SignetLifecycleTests: XCTestCase {
    static let esploraURL = "https://mutinynet.com/api"
    static let faucetURL = URL(string: "https://faucet.mutinynet.com/api/onchain")!
    static let optInMarker = "/tmp/heirloom-signet-optin"
    let delay: UInt32 = 3
    let fundSats: UInt64 = 100_000

    override func setUpWithError() throws {
        let optedIn = ProcessInfo.processInfo.environment["HEIRLOOM_SIGNET"] == "1"
            || FileManager.default.fileExists(atPath: Self.optInMarker)
        try XCTSkipUnless(optedIn, "public signet lifecycle is opt-in: touch \(Self.optInMarker)")
    }

    func testPublicSignetLifecycle() throws {
        // Fresh random seeds for this run only.
        let ownerMnemonic = KeyService.generateMnemonic()
        let heirMnemonic = KeyService.generateMnemonic()
        try KeyService.storeMnemonic(ownerMnemonic, as: .ownerMnemonic)
        try KeyService.storeMnemonic(heirMnemonic, as: .heirMnemonic)

        let network = AppNetwork.signet
        let ownerPub = try KeyService.accountPublicKeyString(mnemonic: ownerMnemonic, network: network)
        let heirPub = try KeyService.accountPublicKeyString(mnemonic: heirMnemonic, network: network)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("heirloom-signet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let owner = try WalletService(
            meta: WalletMeta(
                role: .owner, network: network, delayBlocks: delay, counterpartyKey: heirPub,
                localFingerprint: try KeyService.masterFingerprint(mnemonic: ownerMnemonic, network: network),
                localAccountKey: ownerPub, esploraURL: Self.esploraURL, tier: .free, createdAt: Date()
            ),
            dbPath: tmp.appendingPathComponent("owner.sqlite").path
        )
        let heir = try WalletService(
            meta: WalletMeta(
                role: .heir, network: network, delayBlocks: delay, counterpartyKey: ownerPub,
                localFingerprint: try KeyService.masterFingerprint(mnemonic: heirMnemonic, network: network),
                localAccountKey: heirPub, esploraURL: Self.esploraURL, tier: .free, createdAt: Date()
            ),
            dbPath: tmp.appendingPathComponent("heir.sqlite").path
        )

        // ── 1. Fund: Mutinynet faucet API, or manual faucet fallback ──────
        let fundAddress = try owner.nextReceiveAddress().address.description
        if let faucetTxid = try? requestFaucet(sats: fundSats, address: fundAddress) {
            print("SIGNET EVIDENCE: faucet tx \(faucetTxid) -> \(fundAddress)")
        } else {
            // Faucet APIs come and go (Mutinynet's now needs a token). Manual
            // mode: the operator pastes this address into a signet faucet
            // (e.g. https://faucet.mutinynet.com in a browser) while we poll.
            print("SIGNET MANUAL FUNDING REQUIRED — send sats to: \(fundAddress)")
            print("SIGNET: polling for funds for up to 8 minutes…")
        }

        try waitFor(timeout: 480, poll: { try owner.sync() }) {
            owner.balance().confirmed.toSat() > 0
        }
        var status = owner.lockStatus()
        XCTAssertFalse(status.heirCanClaim)
        XCTAssertEqual(status.blocksRemaining, delay - 1)

        // ── 2. Heartbeat on a public network ──────────────────────────────
        let expiryBefore = try XCTUnwrap(status.earliestExpiryHeight)
        let heartbeat = try owner.prepareHeartbeat(feeRate: max(2, owner.estimatedFeeRate()))
        let heartbeatTxid = try owner.broadcast(heartbeat)
        print("SIGNET EVIDENCE: heartbeat tx \(heartbeatTxid) fee=\(heartbeat.feeSats)sats")

        try waitFor(timeout: 300, poll: { try owner.sync() }) {
            if let expiry = owner.lockStatus().earliestExpiryHeight {
                return expiry > expiryBefore
            }
            return false
        }
        status = owner.lockStatus()
        XCTAssertEqual(status.blocksRemaining, delay - 1, "heartbeat must fully reset the countdown")

        // ── 3. Heir syncs; early claim must fail ──────────────────────────
        try waitFor(timeout: 120, poll: { try heir.fullScan() }) {
            heir.balance().confirmed.toSat() > 0
        }
        // A destination the heir controls (throwaway single-sig wallet).
        let payoutMnemonic = KeyService.generateMnemonic()
        let payoutKey = DescriptorSecretKey(networkKind: .test, mnemonic: payoutMnemonic, password: nil)
        let payoutDescriptor = Descriptor.newBip84(secretKey: payoutKey, keychainKind: .external, networkKind: .test)
        let payoutAddress = try payoutDescriptor.deriveAddress(index: 0, network: .signet).description

        if !heir.lockStatus().heirCanClaim {
            XCTAssertThrowsError(try heir.prepareHeirClaim(toAddress: payoutAddress, feeRate: 2)) { error in
                guard case HeirloomError.timelockNotExpired = error else {
                    return XCTFail("expected timelockNotExpired, got \(error)")
                }
            }
        }

        // ── 4. Wait out the timelock (~90s at 30s blocks), then claim ─────
        try waitFor(timeout: 420, poll: { try heir.sync() }) {
            heir.lockStatus().heirCanClaim
        }
        let claim = try heir.prepareHeirClaim(toAddress: payoutAddress, feeRate: max(2, heir.estimatedFeeRate()))
        let claimTxid = try heir.broadcast(claim) // esplora broadcast = node accepted
        print("SIGNET EVIDENCE: claim tx \(claimTxid) fee=\(claim.feeSats)sats -> \(payoutAddress)")

        try waitFor(timeout: 300, poll: { try heir.sync() }) {
            heir.balance().total.toSat() == 0
        }
        print("SIGNET EVIDENCE: lifecycle complete — verify at https://mutinynet.com/tx/\(claimTxid)")
    }

    // MARK: - Helpers

    private func requestFaucet(sats: UInt64, address: String) throws -> String {
        var request = URLRequest(url: Self.faucetURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sats": sats, "address": address])
        let semaphore = DispatchSemaphore(value: 0)
        var txid: String?
        var failure = "no response"
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { failure = error.localizedDescription; return }
            guard let data else { failure = "empty body"; return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = json["txid"] as? String {
                txid = t
            } else {
                failure = String(decoding: data, as: UTF8.self)
            }
        }.resume()
        semaphore.wait()
        guard let txid else {
            throw HeirloomError.broadcastFailed("faucet: \(failure)")
        }
        return txid
    }

    private func waitFor(
        timeout: TimeInterval,
        poll: () throws -> Void,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                try poll()
                lastError = nil
            } catch {
                lastError = error // transient network errors: keep polling
            }
            if condition() { return }
            Thread.sleep(forTimeInterval: 5)
        }
        if let lastError { throw lastError }
        XCTFail("timed out after \(Int(timeout))s waiting for condition")
    }
}
