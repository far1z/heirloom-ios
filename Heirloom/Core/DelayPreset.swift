import Foundation

/// Inheritance delay presets, expressed as a relative timelock in blocks (BIP-68 CSV).
///
/// Bitcoin averages one block every 10 minutes → 144 blocks/day.
/// The CSV block-count field is 16 bits, so the consensus ceiling is 65,535 blocks
/// (~455 days ≈ 15 months). The "15 months" preset is therefore pinned exactly at
/// the ceiling rather than a naive `15 × 30 × 144` which would overflow it.
enum DelayPreset: UInt32, CaseIterable, Identifiable, Codable {
    /// Approx. blocks per 30.4-day month at 144 blocks/day.
    static let blocksPerMonth: UInt32 = 4_380
    /// BIP-68 relative-timelock ceiling for block-based locks (16-bit field).
    static let csvCeiling: UInt32 = 65_535

    case threeMonths = 13_140
    case sixMonths = 26_280
    case nineMonths = 39_420
    case twelveMonths = 52_560
    /// Capped at the BIP-68 ceiling: 65,535 blocks ≈ 455 days ≈ 15 months.
    case fifteenMonths = 65_535

    var id: UInt32 { rawValue }

    var blocks: UInt32 { rawValue }

    var months: Int {
        switch self {
        case .threeMonths: return 3
        case .sixMonths: return 6
        case .nineMonths: return 9
        case .twelveMonths: return 12
        case .fifteenMonths: return 15
        }
    }

    var title: String {
        switch self {
        case .fifteenMonths: return "~15 months (maximum)"
        default: return "\(months) months"
        }
    }

    var approxDays: Int { Int(blocks) / 144 }

    /// Validates an arbitrary block count for use as a CSV value.
    /// 0 is not a meaningful relative lock; values above 65,535 are not encodable
    /// as block-based BIP-68 locks.
    static func isValidCSV(_ blocks: UInt32) -> Bool {
        blocks >= 1 && blocks <= csvCeiling
    }
}
