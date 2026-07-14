import SwiftUI

enum Theme {
    /// Bitcoin orange.
    static let accent = Color(red: 0.969, green: 0.576, blue: 0.102)
    static let danger = Color(red: 0.90, green: 0.30, blue: 0.25)
    static let ok = Color(red: 0.30, green: 0.78, blue: 0.47)
}

enum Format {
    static func sats(_ value: UInt64) -> String {
        sats(Int64(value))
    }

    static func sats(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        let s = f.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(s) sats"
    }

    static func btc(_ sats: UInt64) -> String {
        String(format: "%.8f sBTC", Double(sats) / 100_000_000)
    }

    static func shortTxid(_ txid: String) -> String {
        guard txid.count > 16 else { return txid }
        return "\(txid.prefix(8))…\(txid.suffix(8))"
    }

    static func blocksAsDuration(_ blocks: UInt32) -> String {
        let days = Double(blocks) / 144.0
        if days >= 2 {
            return "\(Int(days.rounded())) days"
        }
        let hours = Double(blocks) / 6.0
        if hours >= 2 {
            return "\(Int(hours.rounded())) hours"
        }
        return "\(blocks) blocks (~\(blocks * 10) min)"
    }
}

/// Amber/red callout box used for every irreversible or dangerous step.
struct WarningBox: View {
    let title: String
    let message: String
    var severity: Severity = .warning

    enum Severity { case warning, critical }

    var color: Color { severity == .critical ? Theme.danger : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.5)))
    }
}

/// 12-word seed grid. Always `privacySensitive` so iOS redacts it in the app
/// switcher and system screen captures where supported.
struct SeedPhraseGrid: View {
    let words: [String]

    var body: some View {
        grid.privacySensitive()
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(word)
                        .font(.callout.monospaced().weight(.medium))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(destructive ? Theme.danger : Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(destructive ? Color.white : Color.black)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct CopyableText: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                }
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Theme.ok : Theme.accent)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
