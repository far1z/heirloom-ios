# Good morning — overnight build report

Date: 2026-07-14 (overnight session) · Repos:
[heirloom-ios](https://github.com/far1z/heirloom-ios) ·
[heirloom-web](https://github.com/far1z/heirloom-web) · Landing page:
**https://heirloom-web-wine.vercel.app**

## What's done

- **Full iOS app, no stubs in the wallet path.** BDK 3.0 under the hood:
  real BIP-39 key generation, the real 2-key Miniscript policy
  `wsh(or_d(pk(owner),and_v(v:pk(heir),older(N))))`, real PSBT
  construction/signing/broadcast over Esplora or Electrum. Signet default;
  mainnet compiled out behind an OFF `MAINNET_ENABLED` flag labeled
  "NOT AUDITED — DO NOT USE WITH REAL FUNDS".
- **Flows:** creation wizard (how-it-works → delay presets 3/6/9/12/~15 mo
  with the 65,535-block CSV ceiling pinned → Free-vs-Pro → owner seed
  backup + 3-word verification → one-time heir seed handoff → printable
  Heir Recovery Kit), home with live "Your inheritance lock expires in X"
  countdown, one-tap heartbeat with fee display, send, receive with QR,
  guided non-technical heir recovery + claim, settings (endpoint config,
  descriptor export, passcode-gated seed reveal, guarded wipe).
- **Docs:** README (trust model, architecture rationale, verified-vs-not),
  SECURITY.md (private disclosure), SECURITY_REVIEW.md (internal review —
  explicitly not an audit), TESTING.md, CONTRIBUTING.md, this file.
- **Landing page** built and deployed to Vercel production, linking to the
  GitHub repo ("Read the code — it works even if we disappear"), dark-mode,
  Bitcoin-orange, honest not-audited/waitlist framing.

## What's verified (with evidence)

- **App compiles clean; 21 automated tests, 0 failures** (`xcodebuild test`,
  iPhone 17 simulator). Coverage: descriptor/policy construction and
  `sanityCheck`, CSV bounds/ceiling, owner-heir-watchonly derivation
  equality, policy-path resolution, heartbeat build/sign/fee, heir
  pre-maturity refusal, claim nSequence, keyless-service can't sign,
  BIP-68 arithmetic, endpoint security policy, recovery-kit round-trip.
- **Full lifecycle against a real Bitcoin node** (regtest, bitcoind 31.1 +
  electrs, delay = 5 blocks), one run end-to-end:
  fund 1,000,000 sats → countdown exact → heartbeat (fee-asserted,
  confirmed, expiry pushed outward) → **fully-signed early claim rejected
  by bitcoind: `non-BIP68-final`** → one block later accepted → heir claim
  via the app path confirmed → payout exact to the satoshi. Sample
  evidence line from the passing suite:
  `REGTEST LIFECYCLE EVIDENCE: funded=1000000sats heartbeat=f9437d62… claim=c2acf404… receivedBTC=0.00999494`
  (reproduce anytime: `scripts/regtest-up.sh` + `RegtestLifecycleTests`).
- **The app boots and renders** in the simulator (welcome → wizard paths);
  the countdown/heartbeat/claim logic behind every screen is the exact
  code the integration test exercised.
- **Real bugs found and fixed by the tests tonight** (details in
  SECURITY_REVIEW.md §6): a process-aborting overflow inside bdk_wallet 3.0
  when spending unconfirmed CSV UTXOs (now guarded), an xprv-multipath
  descriptor incompatibility (restructured descriptors), and a
  countdown/claim off-by-one (aligned to BIP-68).

## What's blocked and why (see BLOCKED.md)

1. **Public-signet run needs one human faucet interaction** — every faucet
   now demands a CAPTCHA (won't complete those) or GitHub/Lightning auth
   (won't authenticate/pay as you). Ten-minute manual path documented; the
   test does everything else itself.
2. **heirloomcrypto.com** must be attached in the Vercel dashboard (DNS +
   domain settings are account actions).
3. **Physical-device build / TestFlight** needs your Apple Developer team.
4. **BDK upstream bug report** drafted but not filed (would post under your
   identity).

## Your next 3 actions

1. **Run the public-signet lifecycle (10 min):** `touch
   /tmp/heirloom-signet-optin`, run `SignetLifecycleTests` (TESTING.md §3),
   fund the printed address via https://faucet.mutinynet.com (GitHub
   login), and paste the resulting `SIGNET EVIDENCE` txids into the README.
2. **Attach the domain:** Vercel dashboard → `heirloom-web` → Settings →
   Domains → `heirloomcrypto.com`, update DNS at your registrar, then swap
   the URL in both READMEs.
3. **File the BDK issue** from BLOCKED.md §4 — it's a real
   process-abort in the wild for any CSV-descriptor wallet on bdk 3.0.

*(4th, when ready: line up an external security audit — the single gate to
any mainnet conversation.)*
