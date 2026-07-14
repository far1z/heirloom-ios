# Testing Heirloom

Three layers, from fastest to most end-to-end. Everything below has been run
and passes on this repository as of 2026-07-14.

## 1. Unit tests (no infrastructure, run in CI-style)

```bash
xcodegen generate   # once, or after project.yml/file additions
xcodebuild test -project Heirloom.xcodeproj -scheme Heirloom \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Covers: CSV bounds and the 65,535 ceiling, descriptor shape + miniscript
`sanityCheck`, deterministic derivation, owner/heir/watch-only address
equality, recovery-kit round-trips, policy-path resolution, heartbeat
build/sign/finalize with fee assertions, heir pre-maturity refusal, heir
claim nSequence, watch-only spend impossibility, BIP-68 maturity
arithmetic, and the endpoint security policy. The confirmed-UTXO fixtures
are seeded through a custom BDK `Persistence`, so no network is involved.

Status: **21 tests, 0 failures** (regtest/signet tests self-skip without
their infrastructure).

## 2. Regtest lifecycle (local node, real consensus rules)

Requirements: `brew install bitcoin`, `cargo install electrs` (see
`scripts/regtest-up.sh` header for the exact environment used).

```bash
./scripts/regtest-up.sh      # bitcoind regtest :18443 + electrs :60401
xcodebuild test -project Heirloom.xcodeproj -scheme Heirloom \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:HeirloomTests/RegtestLifecycleTests
./scripts/regtest-down.sh
```

`testFullInheritanceLifecycle` (delay = 5 blocks) verifies, in one run:

1. Funding 1,000,000 sats to the inheritance descriptor; countdown numbers
   asserted exactly (expiry = confirmation height + N − 1).
2. Premature claim refused by the app's guard with the correct
   blocks-remaining count.
3. Heartbeat built, fee > 0, broadcast, confirmed; expiry pushed outward;
   balance shrinks by exactly the fee.
4. **Consensus check**: a fully-signed claim with the correct CSV sequence,
   broadcast one block before maturity, rejected by bitcoind with
   `non-BIP68-final` — then accepted after one more block.
5. Heir claim through the app path: built, signed, broadcast, confirmed;
   both wallets drain to zero and the payout address receives
   funded − heartbeat fee − claim fee, exact to the satoshi.

Sample evidence line from a passing run (txids are local-regtest):

```
REGTEST LIFECYCLE EVIDENCE: funded=1000000sats
  heartbeat=f9437d625d5d496822394c44c274d69a30ee95f488a3ae52234725ddb118f12b
  claim=c2acf404efb59e1013ff6b566674377fba79e3d891bd4442941a905bda52bba7
  receivedBTC=0.00999494
```

## 3. Public signet lifecycle (opt-in, manual faucet step)

`SignetLifecycleTests` runs the same lifecycle on a public signet with fresh
random seeds and a 3-block delay. It is opt-in because it depends on
third-party infrastructure:

```bash
touch /tmp/heirloom-signet-optin
xcodebuild test -project Heirloom.xcodeproj -scheme Heirloom \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:HeirloomTests/SignetLifecycleTests
```

The test first tries the Mutinynet faucet API
(`https://faucet.mutinynet.com/api/onchain`). **As of 2026-07-14 that API
requires a captcha token, so funding is manual**: the test prints

```
SIGNET MANUAL FUNDING REQUIRED — send sats to: tb1q…
```

and polls for 8 minutes. While it polls, paste the printed address into
https://faucet.mutinynet.com in a browser and send any amount (Mutinynet
blocks are ~30 s, so the whole lifecycle finishes a few minutes after
funding). The test then runs fund → heartbeat → expiry → claim exactly as
in regtest and prints `SIGNET EVIDENCE:` lines with txids you can open at
`https://mutinynet.com/tx/<txid>`.

To do the same on the *default* signet (10-minute blocks), change
`esploraURL` to `https://mempool.space/signet/api` in the test and use
https://signetfaucet.com — allow several hours of wall-clock time for the
same 3-block delay, and expect to keep the simulator alive that long. The
regtest suite exists precisely because this is slow.

### Manual end-to-end walkthrough in the app UI (signet)

1. Build & run the `Heirloom` scheme in a simulator.
2. "Set up an inheritance wallet" → pick any delay (the descriptor math is
   identical; you cannot practically wait out a 3-month lock on signet —
   use the test suites above for expiry verification).
3. Write down (or screenshot-in-simulator) the two phrases; finish the
   wizard; export the Recovery Kit.
4. Home → Receive → fund the address from https://signetfaucet.com.
5. After 1 confirmation the countdown card activates ("Your inheritance
   lock expires in …"). Send a Heartbeat and watch the fee display,
   broadcast, and countdown reset after confirmation.
6. Settings → Delete wallet. Choose "I am an heir", paste the kit, type the
   heir phrase — the same funds and countdown appear from the heir's
   perspective; the Claim screen explains the waiting state.

## Simulator quirk

If `xcodebuild test` fails with `Simulator device failed to launch …
(Busy)`, the simulator is wedged from a previous crashed run:
`xcrun simctl shutdown all`, wait a few seconds, and re-run.
