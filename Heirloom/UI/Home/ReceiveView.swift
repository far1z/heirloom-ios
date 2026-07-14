import SwiftUI
import CoreImage.CIFilterBuiltins

struct ReceiveView: View {
    @EnvironmentObject var manager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let address {
                        if let qr = Self.qrImage(for: "bitcoin:\(address)") {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        CopyableText(label: "Signet address (fresh, unused)", value: address)
                        Text("Funds sent here are protected by your inheritance policy: you can spend anytime; your heir only after the delay. Get free signet coins from a faucet like signetfaucet.com.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let error {
                        Text(error).foregroundStyle(Theme.danger)
                    } else {
                        ProgressView()
                    }
                }
                .padding()
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear {
                do {
                    address = try manager.service?.nextReceiveAddress().address.description
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    static func qrImage(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
