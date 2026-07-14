# Heirloom

**An open-source iOS Bitcoin inheritance wallet. Your heir can claim your
bitcoin if you go silent — enforced by the Bitcoin network itself, not by a
company, a court, or a custodian.**

> ⚠️ **Signet-only, not audited.** This software runs exclusively on Bitcoin
> signet (test coins). It has not had an independent security audit. A
> mainnet build flag exists but is OFF and marked
> **NOT AUDITED — DO NOT USE WITH REAL FUNDS**. See
> [SECURITY_REVIEW.md](SECURITY_REVIEW.md).

Landing page: https://heirloom-web-wine.vercel.app · Web repo:
[heirloom-web](https://github.com/far1z/heirloom-web)

---

## The trust model — "it works even if we disappear"

Heirloom is a **2-key Miniscript timelock wallet**:

```
wsh(or_d(pk(OWNER), and_v(v:pk(HEIR), older(DELAY))))
```

| Actor | What their key can do |
|---|---|
| **Owner** | Spend anytime, no waiting, no cosigner. |
| **Heir** | Spend only after the coins have sat still for `DELAY` blocks (3–15 months; presets 3/6/9/12/~15). |
| **Heirloom (us)** | Nothing. There is no third key. Provably — see the watch-only signing test. |

Every time the owner moves the coins — including the one-tap **heartbeat**,
a self-spend back into the same policy — every coin's clock restarts. Active
owner ⇒ heir can't spend. Owner goes permanently silent (death, incapacity,
lost keys) ⇒ the delay elapses and the heir's own key unlocks the funds,
guided by a recovery flow written for someone who has never used Bitcoin.

Non-custodial to the bone:

- Both seeds are generated on-device (BIP-39) and never leave it. The
  owner's phone keeps only the *public* key of the heir, and vice versa.
- No backend, no accounts. Chain access is any public or self-hosted
  Esplora/Electrum endpoint (configurable in Settings).
- If this company, this repo, and every server we ever ran vanished
  tonight, the wallet still works: the policy lives on the Bitcoin
  blockchain, and the two seeds + the printed Recovery Kit reconstruct
  everything in Bitcoin Core, Sparrow, or bdk-cli.
- **Pro tier** (shown during setup, entirely optional, client-side
  representation only today) will be a managed *reminder* service for
  heartbeats. It never holds keys and can never move a satoshi — a
  property enforced by the script, not by our promises.

## Architecture and why

| Decision | Why |
|---|---|
| **BDK 3.0 (`bdk-swift`)** for all wallet logic | The reference Rust implementation of descriptors/Miniscript — the same engine used across the industry. Real BIP-39/BIP-32, real PSBT signing, real Esplora/Electrum sync; no hand-rolled crypto anywhere in this repo. Single pinned dependency. |
| **`or_d(pk, and_v(v:pk, older))`** policy | The canonical primary-key + timelocked-recovery construction: cheapest owner spends, non-malleable, standard, and `sanityCheck`-clean. CSV (relative) rather than CLTV (absolute) so the lock *renews itself* on every spend — that's what makes heartbeats work. |
| **BIP-68 ceiling respected** | CSV block locks are 16-bit: max 65,535 blocks ≈ 455 days. The "15 months" preset *is* the ceiling; the UI says so. |
| **BIP-48-style derivation** (`m/48'/coin'/0'/2'`), two single-path descriptors (`/0/*`, `/1/*`) | Multipath `<0;1>` expressions can't contain an xprv (rust-miniscript limitation, found by our tests), so external/change descriptors are built explicitly. Owner and heir devices provably derive identical addresses. |
| **Keychain, `WhenUnlockedThisDeviceOnly`** | Strongest non-syncing class: never in backups, never on other devices. The Secure Enclave can't hold secp256k1 keys (P-256 only) — we say so honestly instead of marketing around it. |
| **SwiftUI + XcodeGen** | Project is regenerated from `project.yml`; no merge-hostile `.xcodeproj` churn. iOS 17+. |
| **Signet default, regtest for CI, mainnet compiled out** | You can't lose money that can't exist in the build. |

Code map: `Heirloom/Core/` (policy, keys, wallet service, chain client — no
UI), `Heirloom/UI/` (wizard, home + countdown, heartbeat, heir recovery,
settings), `HeirloomTests/`, `scripts/` (regtest harness).

## Build and run

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/far1z/heirloom-ios && cd heirloom-ios
xcodegen generate
xcodebuild build -project Heirloom.xcodeproj -scheme Heirloom \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

or just `open Heirloom.xcodeproj` and hit Run. Get signet coins at
https://signetfaucet.com (or use https://mutinynet.com for 30-second
blocks). First launch walks you through the full setup, including the
printed **Heir Recovery Kit**.

## What has been verified — and what hasn't

**Verified** (all reproducible; see [TESTING.md](TESTING.md)):

- ✅ 21 automated tests, 0 failures: policy/descriptor construction, CSV
  ceiling, derivation symmetry, policy-path selection, tx building/signing,
  heir-claim path, endpoint policy, recovery-kit round-trip.
- ✅ **Full lifecycle against a real Bitcoin node** (regtest, delay = 5
  blocks): fund → countdown → heartbeat resets clock → *fully-signed early
  claim rejected by bitcoind with `non-BIP68-final`* → expiry → heir claim
  accepted and confirmed → payout exact to the satoshi.
- ✅ A keyless watch-only wallet (i.e., anything a service could hold)
  cannot sign either branch.
- ✅ App and test suite compile clean; the crash we found in the underlying
  library (unchecked height addition on unconfirmed CSV inputs in
  bdk_wallet 3.0) is guarded at our boundary.

**Not verified / not done:**

- ❌ No independent security audit (required before mainnet).
- ❌ Public-signet lifecycle requires a manual faucet step (captchas are
  not bypassed); the opt-in test walks you through it in ~10 minutes on
  Mutinynet. Consensus behavior is fully covered on regtest, which runs
  the same rules.
- ❌ No physical-device (App Store) distribution yet; simulator/dev builds.
- ❌ Fee-bumping (RBF/CPFP) for a stuck claim, multi-endpoint chain
  cross-checking, and biometric spend gating are known gaps —
  see [SECURITY_REVIEW.md §10](SECURITY_REVIEW.md).

## Security disclosure

Report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/far1z/heirloom-ios/security/advisories/new)
— never in public issues. Policy, response times, and scope:
[SECURITY.md](SECURITY.md). Internal review, findings, and residual risks:
[SECURITY_REVIEW.md](SECURITY_REVIEW.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: the policy stays
simple, signet stays the default, security reports stay private, and
`Core/` changes need tests.

## License

[MIT](LICENSE) — because inheritance software you can't read, fork, and
rebuild yourself misses the entire point.
