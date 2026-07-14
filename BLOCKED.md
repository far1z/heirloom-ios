# Blocked items (need a human)

Items that could not be completed autonomously overnight, why, and exactly
what you need to do.

## 1. Public-signet lifecycle needs one manual faucet click

**Why blocked:** every public signet faucet now requires a human:
signetfaucet.com uses an image CAPTCHA (I don't complete CAPTCHAs), and
faucet.mutinynet.com now requires GitHub login or a Lightning payment (I
don't authenticate or pay on your behalf).

**Impact:** low. The identical lifecycle (fund → heartbeat → early-claim
rejected by the node with `non-BIP68-final` → expiry → heir claim →
funds move) is fully verified against real consensus rules on regtest —
see TESTING.md §2 for the evidence.

**Your 10-minute path to public txids (Mutinynet, 30-second blocks):**

```bash
cd heirloom-ios
touch /tmp/heirloom-signet-optin
xcodebuild test -project Heirloom.xcodeproj -scheme Heirloom \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:HeirloomTests/SignetLifecycleTests
```

When the log prints `SIGNET MANUAL FUNDING REQUIRED — send sats to: tb1q…`,
open https://faucet.mutinynet.com, sign in with GitHub, send ~100,000 sats
to that address, and wait. The test finishes the whole lifecycle by itself
and prints `SIGNET EVIDENCE:` txids viewable at https://mutinynet.com.

## 2. heirloomcrypto.com domain

The landing page is live at **https://heirloom-web-wine.vercel.app**
(project `heirloom-web`, account `far1z`). Attaching the custom domain
requires the Vercel dashboard (and DNS you control):
Vercel → heirloom-web → Settings → Domains → add `heirloomcrypto.com`,
then point DNS (A 216.198.79.65 apex / CNAME to the value Vercel shows for www)
at your registrar. (Also update the URL in this repo's README + web README once live.)

## 3. Running on a physical iPhone / TestFlight

Needs your Apple Developer account (signing team). Simulator builds and the
whole test suite work without it. In Xcode: select your team on the
Heirloom target, or add `DEVELOPMENT_TEAM` to project.yml.

## 4. Upstream bug report to BDK

Found tonight: `bdk_wallet 3.0.0` `Older::check_older` does
`create_height + N` with `.expect("Overflowing addition")`, which aborts the
process when spending an unconfirmed UTXO of a CSV descriptor (unconfirmed
create-height sentinel = u32::MAX). Guarded on our side
(owner spends `excludeUnconfirmed()`), but it should be reported to
https://github.com/bitcoindevkit/bdk — I did not file the issue because it
would be posted under your GitHub identity. Suggested title:
"Older::check_older panics (overflow) when satisfying older() against an
unconfirmed UTXO". Repro: build an owner-branch spend of an unconfirmed
UTXO on the descriptor in this repo at commit `04fc66f` (before the
excludeUnconfirmed guard landed in `f0288cd`), or ask me to write a
minimal Rust repro.
