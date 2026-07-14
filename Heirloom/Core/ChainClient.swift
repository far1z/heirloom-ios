import Foundation
import BitcoinDevKit

/// Abstraction over BDK's blockchain backends.
///
/// The endpoint URL scheme selects the client:
///  - `http://` / `https://` → Esplora REST
///  - `tcp://` / `ssl://`   → Electrum protocol
///
/// Both only ever receive public data (scripts, transactions). Keys never touch
/// this layer.
enum ChainClient {
    case esplora(EsploraClient)
    case electrum(ElectrumClient)

    init(endpoint: String) throws {
        guard Self.isAcceptableEndpoint(endpoint) else {
            throw HeirloomError.invalidEndpoint(endpoint)
        }
        if endpoint.hasPrefix("tcp://") || endpoint.hasPrefix("ssl://") {
            self = .electrum(try ElectrumClient(url: endpoint))
        } else if endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://") {
            self = .esplora(EsploraClient(url: endpoint))
        } else {
            throw HeirloomError.invalidEndpoint(endpoint)
        }
    }

    /// A chain server never sees keys, but a *lying* one can hide UTXOs and
    /// transactions — including heartbeats — and skew fee estimates. Plaintext
    /// transports invite exactly that tampering, so they are only accepted for
    /// loopback (regtest/self-hosted development).
    static func isAcceptableEndpoint(_ endpoint: String) -> Bool {
        if endpoint.hasPrefix("https://") || endpoint.hasPrefix("ssl://") { return true }
        if endpoint.hasPrefix("http://") || endpoint.hasPrefix("tcp://") {
            let rest = endpoint.components(separatedBy: "://").dropFirst().joined()
            let host = rest.split(separator: "/").first?.split(separator: ":").first.map(String.init) ?? ""
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }
        return false
    }

    func sync(request: SyncRequest) throws -> Update {
        switch self {
        case .esplora(let client):
            return try client.sync(request: request, parallelRequests: 4)
        case .electrum(let client):
            return try client.sync(request: request, batchSize: 10, fetchPrevTxouts: true)
        }
    }

    func fullScan(request: FullScanRequest, stopGap: UInt64) throws -> Update {
        switch self {
        case .esplora(let client):
            return try client.fullScan(request: request, stopGap: stopGap, parallelRequests: 4)
        case .electrum(let client):
            return try client.fullScan(request: request, stopGap: stopGap, batchSize: 10, fetchPrevTxouts: true)
        }
    }

    func broadcast(_ tx: Transaction) throws {
        switch self {
        case .esplora(let client):
            try client.broadcast(transaction: tx)
        case .electrum(let client):
            _ = try client.transactionBroadcast(tx: tx)
        }
    }

    /// Estimated fee rate in sat/vB for a confirmation target, 1 sat/vB floor.
    func feeRate(targetBlocks: UInt16) -> UInt64 {
        switch self {
        case .esplora(let client):
            guard let estimates = try? client.getFeeEstimates() else { return 1 }
            let satVb = estimates[targetBlocks] ?? estimates.values.min() ?? 1
            return max(1, UInt64(satVb.rounded()))
        case .electrum(let client):
            // estimateFee returns BTC/kB; convert to sat/vB.
            guard let btcPerKb = try? client.estimateFee(number: UInt64(targetBlocks)), btcPerKb > 0 else {
                return 1
            }
            return max(1, UInt64((btcPerKb * 100_000_000 / 1_000).rounded()))
        }
    }
}
