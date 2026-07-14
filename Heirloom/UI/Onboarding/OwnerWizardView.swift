import SwiftUI
import BitcoinDevKit

/// Multi-step wallet-creation wizard for the owner.
///
/// Steps: how-it-works → delay → tier → owner seed backup+verify →
/// heir seed handoff → final review → create.
struct OwnerWizardView: View {
    @EnvironmentObject var manager: WalletManager
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case howItWorks, delay, tier, ownerSeed, ownerVerify, heirSeed, review
    }

    @State private var step: Step = .howItWorks
    @State private var delay: DelayPreset = .twelveMonths
    @State private var tier: ServiceTier = .free

    // Seed material lives only for the duration of the wizard.
    @State private var ownerMnemonic = KeyService.generateMnemonic()
    @State private var heirMnemonic = KeyService.generateMnemonic()
    @State private var ownerWords: [String] = []
    @State private var heirWords: [String] = []

    @State private var verifyIndices: [Int] = []
    @State private var verifyInput: [String] = ["", "", ""]
    @State private var verifyError = false

    @State private var confirmedHeirHandoff = false
    @State private var acknowledgedTimelock = false
    @State private var isCreating = false
    @State private var creationError: String?
    @State private var recoveryKit: RecoveryKit?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(Theme.accent)

                switch step {
                case .howItWorks: howItWorks
                case .delay: delayPicker
                case .tier: tierPicker
                case .ownerSeed: ownerSeedBackup
                case .ownerVerify: ownerSeedVerify
                case .heirSeed: heirSeedHandoff
                case .review: review
                }
            }
            .padding()
        }
        .navigationTitle("New wallet")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ownerWords = ownerMnemonic.description.split(separator: " ").map(String.init)
            heirWords = heirMnemonic.description.split(separator: " ").map(String.init)
            verifyIndices = Array(0..<12).shuffled().prefix(3).sorted()
        }
    }

    // MARK: Step 1 — how it works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How Heirloom works").font(.title2.bold())

            explainerRow(
                icon: "key.fill",
                title: "Two keys, one wallet",
                text: "Your key spends anytime. Your heir's key only works after a waiting period of inactivity — enforced by Bitcoin itself, not by us."
            )
            explainerRow(
                icon: "heart.fill",
                title: "Heartbeats keep control with you",
                text: "Any time you move your coins — including a one-tap “heartbeat” to yourself — the waiting period restarts. Active owner ⇒ heir cannot spend."
            )
            explainerRow(
                icon: "clock.fill",
                title: "If you go silent, your heir inherits",
                text: "If you never move the coins (death, lost phone, lost keys), the clock runs out and your heir can claim the funds with their own key — no company, no court, no custodian."
            )
            explainerRow(
                icon: "eye.slash.fill",
                title: "Non-custodial by design",
                text: "Keys are generated on this device and never leave it. Heirloom-the-company can disappear and everything still works: the rules live on the Bitcoin blockchain."
            )

            WarningBox(
                title: "The trade-off you accept",
                message: "If you stop refreshing the clock — for ANY reason — your heir can take the funds after the delay. And if you lose BOTH your key and your heir's key, the funds are gone forever. There is no recovery service."
            )

            Button("I understand — continue") { step = .delay }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func explainerRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 2 — delay

    private var delayPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the inheritance delay").font(.title2.bold())
            Text("How long must your wallet be inactive before your heir can claim? Every time you send a heartbeat, this clock restarts from zero.")
                .font(.callout).foregroundStyle(.secondary)

            ForEach(DelayPreset.allCases) { preset in
                Button {
                    delay = preset
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(.headline)
                            Text("\(preset.blocks) blocks · ~\(preset.approxDays) days")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: delay == preset ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(delay == preset ? Theme.accent : .secondary)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(delay == preset ? 0.7 : 0.35), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Text("Bitcoin's relative-timelock ceiling is 65,535 blocks, so ~15 months is the maximum possible delay.")
                .font(.caption2).foregroundStyle(.secondary)

            WarningBox(
                title: "Pick honestly",
                message: "Shorter delays mean your heir waits less, but YOU must check in more often. If you can't send a heartbeat for \(delay.title.lowercased()) (illness, prison, lost device without backup), your heir gains spending power."
            )

            Button("Continue") { step = .tier }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Step 3 — tier

    private var tierPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your plan").font(.title2.bold())
            Text("Both plans are fully non-custodial. Neither Heirloom nor anyone else ever holds a key that can move your funds.")
                .font(.callout).foregroundStyle(.secondary)

            tierCard(
                .free,
                name: "Free",
                price: "$0 forever",
                features: [
                    "Full inheritance wallet",
                    "Manual heartbeats from this app",
                    "Local reminders before the clock runs out",
                    "Open source — works even if we disappear",
                ]
            )
            tierCard(
                .pro,
                name: "Pro",
                price: "Coming soon",
                features: [
                    "Everything in Free",
                    "Managed heartbeat reminders across email/SMS",
                    "Multi-channel dead-man checks before your clock expires",
                    "Still zero custody: our servers can never move a single sat",
                ]
            )

            Text("Pro is a convenience service only. If Pro servers vanish, your wallet and your heir's claim work exactly the same.")
                .font(.caption2).foregroundStyle(.secondary)

            Button("Continue") { step = .ownerSeed }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func tierCard(_ value: ServiceTier, name: String, price: String, features: [String]) -> some View {
        Button {
            tier = value
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name).font(.headline)
                    Spacer()
                    Text(price).font(.caption).foregroundStyle(Theme.accent)
                    Image(systemName: tier == value ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(tier == value ? Theme.accent : .secondary)
                }
                ForEach(features, id: \.self) { feature in
                    Label(feature, systemImage: "checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(tier == value ? 0.7 : 0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 4 — owner seed

    private var ownerSeedBackup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your recovery phrase").font(.title2.bold())
            Text("These 12 words ARE your money. Write them on paper, in order. Store the paper somewhere safe. You will confirm three of them on the next screen.")
                .font(.callout).foregroundStyle(.secondary)

            SeedPhraseGrid(words: ownerWords)

            WarningBox(
                title: "Never digital, never shared",
                message: "Do not screenshot, photograph, type into a notes app, or read these words aloud. Anyone with these 12 words can take everything, instantly, from anywhere.",
                severity: .critical
            )

            Button("I wrote down all 12 words") { step = .ownerVerify }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var ownerSeedVerify: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm your backup").font(.title2.bold())
            Text("Enter the requested words from your paper backup.")
                .font(.callout).foregroundStyle(.secondary)

            ForEach(Array(verifyIndices.enumerated()), id: \.offset) { slot, wordIndex in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Word #\(wordIndex + 1)").font(.caption).foregroundStyle(.secondary)
                    TextField("word \(wordIndex + 1)", text: $verifyInput[slot])
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            }

            if verifyError {
                Text("One or more words don't match. Check your paper backup and try again.")
                    .font(.footnote).foregroundStyle(Theme.danger)
            }

            Button("Verify") {
                let ok = verifyIndices.enumerated().allSatisfy { slot, wordIndex in
                    verifyInput[slot].trimmingCharacters(in: .whitespaces).lowercased() == ownerWords[wordIndex]
                }
                if ok {
                    verifyError = false
                    step = .heirSeed
                } else {
                    verifyError = true
                }
            }
            .buttonStyle(PrimaryButtonStyle())

            Button("Show the words again") { step = .ownerSeed }
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Step 5 — heir seed

    private var heirSeedHandoff: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your heir's recovery phrase").font(.title2.bold())
            Text("This is a SEPARATE phrase for your heir. Write it on its own piece of paper. Give it to your heir (or store it where they will find it — with your will, in a safe, with your lawyer).")
                .font(.callout).foregroundStyle(.secondary)

            SeedPhraseGrid(words: heirWords)

            WarningBox(
                title: "Shown once, then gone",
                message: "For your security this phone does NOT keep the heir's phrase. After this step it cannot be shown again. If it is lost before your heir needs it, the inheritance path is lost too — only your own key would remain.",
                severity: .critical
            )
            WarningBox(
                title: "Keep the two papers apart",
                message: "Anyone holding your heir's phrase must still wait out the \(delay.title) delay — but don't make it easy. Store the two phrases in different places."
            )

            Toggle(isOn: $confirmedHeirHandoff) {
                Text("I wrote down the heir phrase and understand it will never be shown again.")
                    .font(.footnote)
            }
            .tint(Theme.accent)

            Button("Continue") { step = .review }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!confirmedHeirHandoff)
                .opacity(confirmedHeirHandoff ? 1 : 0.5)
        }
    }

    // MARK: Step 6 — review & create

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review").font(.title2.bold())

            LabeledContent("Network", value: "Signet (test coins)")
            LabeledContent("Inheritance delay", value: "\(delay.title) · \(delay.blocks) blocks")
            LabeledContent("Plan", value: tier == .free ? "Free" : "Pro")
            Divider()

            WarningBox(
                title: "What you are agreeing to",
                message: "① If this wallet sees no outgoing transaction for \(delay.title.lowercased()), your heir can spend every coin in it. ② Heartbeats require an on-chain transaction and cost a network fee. ③ If you lose your phrase AND your heir loses theirs, nobody on earth can recover the funds."
            )

            Toggle(isOn: $acknowledgedTimelock) {
                Text("I understand that heir access after \(delay.title.lowercased()) of inactivity is automatic and cannot be cancelled without moving my coins.")
                    .font(.footnote)
            }
            .tint(Theme.accent)

            if let error = creationError {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }

            if let kit = recoveryKit {
                kitExport(kit)
            } else {
                Button {
                    createWallet()
                } label: {
                    if isCreating {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 4)
                    } else {
                        Text("Create wallet")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!acknowledgedTimelock || isCreating)
                .opacity(acknowledgedTimelock ? 1 : 0.5)
            }
        }
    }

    private func kitExport(_ kit: RecoveryKit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Wallet created", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.ok)
            Text("Last step: save the Heir Recovery Kit. Your heir needs it (plus their 12 words) to claim. Print it or store it with your estate documents. It contains no secret keys but reveals wallet history — keep it private.")
                .font(.footnote).foregroundStyle(.secondary)

            ShareLink(item: kit.humanReadableDocument()) {
                Text("Share / print recovery kit")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black)
            }

            Button("Done") { dismiss() }
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
    }

    private func createWallet() {
        isCreating = true
        creationError = nil
        Task {
            do {
                let network = AppNetwork.signet
                let heirKey = try KeyService.accountPublicKeyString(mnemonic: heirMnemonic, network: network)
                let heirFingerprint = try KeyService.masterFingerprint(mnemonic: heirMnemonic, network: network)
                try await manager.createOwnerWallet(
                    ownerMnemonic: ownerMnemonic,
                    heirAccountKey: heirKey,
                    heirFingerprint: heirFingerprint,
                    delayBlocks: delay.blocks,
                    tier: tier,
                    network: network
                )
                let kit = RecoveryKit(
                    network: network,
                    delayBlocks: delay.blocks,
                    ownerAccountKey: try KeyService.accountPublicKeyString(mnemonic: ownerMnemonic, network: network),
                    heirAccountKey: heirKey,
                    heirFingerprint: heirFingerprint,
                    createdAt: Date()
                )
                recoveryKit = kit
            } catch {
                creationError = error.localizedDescription
            }
            isCreating = false
        }
    }
}
