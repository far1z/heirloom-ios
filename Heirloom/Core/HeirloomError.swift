import Foundation

enum HeirloomError: LocalizedError, Equatable {
    case invalidDelay(UInt32)
    case keychainError(OSStatus)
    case seedNotFound
    case walletNotInitialized
    case invalidMnemonic
    case invalidEndpoint(String)
    case policyPathNotFound(String)
    case timelockNotExpired(blocksRemaining: UInt32)
    case nothingToSpend
    case waitingForConfirmation
    case invalidAddress(String)
    case broadcastFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDelay(let blocks):
            return "Invalid inheritance delay: \(blocks) blocks. Must be between 1 and \(DelayPreset.csvCeiling)."
        case .keychainError(let status):
            return "Secure storage error (OSStatus \(status))."
        case .seedNotFound:
            return "No wallet seed found in secure storage."
        case .walletNotInitialized:
            return "The wallet has not been set up yet."
        case .invalidMnemonic:
            return "That recovery phrase is not valid. Check every word and try again."
        case .invalidEndpoint(let url):
            return "Invalid server URL: \(url)"
        case .policyPathNotFound(let what):
            return "Could not locate the \(what) spending path in the wallet policy."
        case .timelockNotExpired(let remaining):
            return "The inheritance timelock has not expired yet. \(remaining) more blocks (~\(remaining / 144) days) are required."
        case .nothingToSpend:
            return "There are no confirmed funds to spend."
        case .waitingForConfirmation:
            return "Your funds are still waiting for their first confirmation. Try again in a few minutes — the inheritance clock (and heartbeats) only apply to confirmed coins."
        case .invalidAddress(let addr):
            return "Invalid Bitcoin address for this network: \(addr)"
        case .broadcastFailed(let msg):
            return "Broadcast failed: \(msg)"
        }
    }
}
