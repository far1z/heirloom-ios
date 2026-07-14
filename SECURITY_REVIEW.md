# Heirloom — Internal Security Self-Review

> **This is an internal review performed by the project's own developer
> (an AI agent), not an independent audit. It is a map of what was examined,
> what was fixed, and what risk remains — not a certification. An external,
> professional security audit is REQUIRED before this software is used on
> mainnet or with anything of value. The mainnet build flag is off and must
> stay off until that happens.**

Review date: 2026-07-14 · Scope: entire `heirloom-ios` codebase at the commit
introducing this document, reviewed from a hostile-attacker perspective.

---

## 1. Threat model

Assets: the owner seed, the heir seed (displayed once), and the funds locked
by the descriptor. Adversaries considered:

- **A1 — remote attacker** with no device access (network position, malicious
  chain server, malicious counterparty in the descriptor).
- **A2 — device thief** with a locked, then unlocked, device.
- **A3 — the service operator** (us): could Heirloom-the-company, or its Pro
  heartbeat service, ever move funds or hold users hostage?
- **A4 — the heir** trying to spend early; **A5 — the owner's estate
  adversaries** trying to block the heir after death.
- **A6 — supply chain** (dependencies, build).

## 2. Policy correctness (the money-losing questions)

The single policy in the product:

```
wsh(or_d(pk(OWNER/⟨0,1⟩/*), and_v(v:pk(HEIR/⟨0,1⟩/*), older(DELAY))))
```

**Could the heir spend early?** No, and this is enforced by Bitcoin consensus,
not by app code. The heir branch requires `older(DELAY)` (BIP-68, OP_CSV):
the spending input's nSequence must encode ≥DELAY and the spent UTXO must
have ≥DELAY confirmations. Verified three ways:
- Unit: an heir-side wallet cannot finalize any spend of an immature UTXO,
  under either policy path (`testHeirCannotSpendBeforeTimelockMatures`).
- Consensus: a fully-signed claim with correct CSV sequence, broadcast one
  block before maturity, is rejected by bitcoind with `non-BIP68-final`
  (`RegtestLifecycleTests`), then accepted one block later.
- Static: `Descriptor.sanityCheck()` is asserted at every parse, so the
  descriptor is standard, non-malleable, and all paths require a signature.

**Could the heartbeat key / Pro service ever move funds?** There is no
heartbeat key. A heartbeat is an ordinary owner-branch self-spend; the Pro
tier (client-side representation only today) holds no key material of any
kind. `testWatchOnlyServiceCannotSignAnything` proves a wallet holding
everything a service could ever hold (both public keys, full chain view)
cannot produce a single signature on either branch.

**Could we (A3) censor or ransom?** No key, no server dependency: the wallet
talks to a user-configurable public Esplora/Electrum endpoint. If every
Heirloom endpoint and repository disappeared, the descriptor + two seeds
reconstruct the wallet in any descriptor-capable tool (Bitcoin Core,
Sparrow, bdk-cli). The heir Recovery Kit contains everything needed except
the heir's own seed.

**Owner lockout (A5)?** The owner branch has no timelock; the owner can
always sweep, including after the heir's branch has matured (verified in the
regtest lifecycle: heartbeat works at any age). If the owner loses their
seed, the heir path still works — that's the product. If both seeds are
lost, funds are gone; the UI warns about this at three separate steps.

**CSV ceiling.** All delays are validated to 1…65,535 blocks; the 15-month
preset is pinned exactly at the BIP-68 16-bit ceiling
(`testDelayPresetBlockValues`, `testCSVBoundsValidation`). Time-based (bit-22)
locks are never used, so there is no unit confusion.

**Derivation symmetry.** Owner device, heir device, and pure watch-only
builds derive byte-identical scripts for the same inputs
(`testOwnerHeirAndWatchOnlyDeriveIdenticalAddresses`) — heir recovery cannot
scan an empty wallet because of a derivation mismatch.

## 3. Key material handling

| Item | Where it lives | Notes |
|---|---|---|
| Owner seed | iOS Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (+ `kSecUseDataProtectionKeychain` on device) | Never in backups, never synced, never leaves the device. Loaded into memory to derive/sign. |
| Heir seed (during setup) | Wizard memory only | Shown once, never persisted on the owner's device; only its account xpub is kept. |
| Heir seed (heir's device) | Keychain, same class | Stored only after the typed phrase is verified against the kit's xpub. |
| Descriptors with xprv | Process memory during wallet construction | BDK requires string interpolation of the signer key; never logged, never persisted (BDK strips secrets before persisting — verified: the SQLite changeset stores public descriptors only). |

**Secure Enclave, honestly.** The SE performs P-256 only; a secp256k1
Bitcoin key cannot live inside it. Heirloom uses the industry-standard
alternative: Keychain data protection (whose class keys are SE-guarded) with
the strictest non-synchronizing accessibility class. Marketing this as
"keys in the Secure Enclave" would be false; we don't.

**Memory hygiene limits.** Swift `String`/BDK Rust objects cannot be
reliably zeroized; seeds and derived keys exist transiently in process
memory whenever the wallet is open. This is the norm for mobile wallets and
is listed as a residual risk. Mitigations: no logging of secrets anywhere
(grep-verified), seed UI is `privacySensitive`, reveal requires
device-owner authentication (LAContext), and the app runs on signet.

**Fixed findings in this area:**
- **[FIXED] Seed grids were not `privacySensitive`** in the wizard — the app
  switcher snapshot could contain the words. Now applied inside
  `SeedPhraseGrid` itself so no call site can forget it.
- **[FIXED] Keychain items previously written with signing disabled** meant
  the test host lacked its app-identifier entitlement (errSecMissingEntitlement)
  — ad-hoc signing restored; on-device builds always had this.

## 4. Seed backup / export flow

- Backup is paper-only by instruction; the app never offers a digital export
  of a seed. Reveal (Settings) requires `deviceOwnerAuthentication` and
  fails closed when no passcode is set.
- The wizard forces a 3-word spot check of the owner seed before proceeding,
  and an explicit acknowledgment that the heir phrase is shown exactly once.
- The Recovery Kit deliberately contains only public keys + the delay, and
  its document says in plain language that it cannot move funds but should
  be kept private (xpubs reveal history — a privacy, not custody, risk).
- Clipboard: seeds are never copyable. Descriptors/xpubs/txids are (with
  the same privacy caveat); an attacker with clipboard access gets no
  spending power.

## 5. Network layer

- Chain access is Esplora (HTTPS) or Electrum (SSL), user-configurable.
  **[FIXED]** Plaintext `http://`/`tcp://` endpoints are now rejected unless
  the host is loopback (regtest/self-hosted development). A malicious chain
  server can never steal funds (it sees only scripts and transactions,
  never keys) but could *lie*: hide incoming funds, hide heartbeats, report
  stale tips, or skew fee estimates. Consequences and their mitigations:
  - Wrong countdown display → the countdown is computed from UTXO
    confirmation heights the server reports; a lying server could make the
    owner believe the lock is fresher than it is. Mitigation: endpoint is
    user-controllable (run your own), and the descriptor can be watched in
    any independent tool. Documented in README; a multi-source
    cross-check is future work.
  - Fee-rate manipulation → fee is displayed in sats before broadcast and
    the rate is floor-clamped at 1 sat/vB; absurd fees require explicit
    user confirmation of the shown amount.
- The wallet never transmits xpubs or descriptors; sync queries are
  per-script (standard Esplora/Electrum protocol). Address-set linkage by
  the server is inherent to these protocols and documented in Settings.
- No analytics, no telemetry, no third-party SDKs, zero network calls
  outside the configured chain endpoint (grep-verified: the only URLSession
  uses are in the test faucet helper).

## 6. Application logic

- **[FIXED — crash, found by tests] bdk_wallet 3.0 `Older::check_older`
  performs `create_height + N` with `.expect("Overflowing addition")`**; for
  an unconfirmed UTXO the create height is a `u32::MAX` sentinel, so
  building an owner-branch spend that selects an unconfirmed UTXO of this
  CSV descriptor aborts the whole process (Rust panic — not catchable from
  Swift). Owner-side builders now `excludeUnconfirmed()` and fail with a
  friendly "wait for confirmation" error when nothing confirmed exists.
  This is also the correct product semantics (a heartbeat only counts once
  confirmed). *Action item: report upstream to bitcoindevkit.*
- **[FIXED — off-by-one] countdown vs. claim gate**: `lockStatus` previously
  showed "1 block remaining" at the exact height where a claim was already
  mempool-valid. Both now use the same BIP-68 rule (claimable at exactly N
  confirmations, i.e. tip = h+N−1), asserted block-by-block in regtest.
- Policy paths are always explicit (`TxBuilder.policyPath` on both
  keychains) — the wallet never relies on BDK's implicit branch choice, so
  nSequence values are always the ones we intend. The loaded wallet's
  policy CSV is cross-checked against stored metadata at startup; a
  mismatch (corrupted/tampered state) refuses to open rather than silently
  operating on the wrong descriptor.
- Heir claims sweep only matured UTXOs (`manuallySelectedOnly`), so a
  premature claim cannot be constructed even if the UI is bypassed.
- Wallet deletion requires a typed-style confirmation dialog and destroys
  Keychain items, metadata, and chain databases; the funds' fate (still on
  chain, needs paper backup) is stated in the dialog.

## 7. Data at rest

- Wallet metadata (xpubs, delay, endpoint): Application Support, file
  protection `completeUntilFirstUserAuthentication`, excluded from backup.
- **[FIXED]** BDK SQLite chain databases now share the backup exclusion
  (public descriptors inside would otherwise leak wallet history through
  iCloud/iTunes backups).
- No secrets in `UserDefaults`, no plists with sensitive content.

## 8. Dependency & supply-chain risk

- Exactly one third-party dependency: `bdk-swift 3.0.0` (BitcoinDevKit),
  pinned by exact version; SPM verifies the binary artifact checksum from
  the pinned `Package.swift`. BDK is the most widely reviewed wallet
  library in the ecosystem, but it ships as a prebuilt xcframework — a
  reproducible from-source build of bdk-ffi is future work and a
  precondition for any mainnet release.
- No CocoaPods, no analytics SDKs, no JS. XcodeGen is a dev-time tool only.
- The Rust panic found tonight (see §6) is a reminder that even
  high-quality dependencies fail in edges; the app's policy is to guard at
  the boundary (input filtering) rather than assume library totality.

## 9. Mainnet gate

- Mainnet exists only behind the `MAINNET_ENABLED` Swift compilation
  condition, which no checked-in configuration defines. Even when defined,
  the creation wizard hardcodes signet; enabling mainnet requires deliberate
  code changes plus the flag. The flag's documentation string reads
  **"NOT AUDITED — DO NOT USE WITH REAL FUNDS"** and that is the accurate
  status of this codebase.

## 10. Residual risks (open, by design or pending)

1. **No independent audit.** The dominant risk. Required before mainnet.
2. **Seed material in process memory** while the wallet is open
   (platform/BDK limitation; industry-standard exposure).
3. **Single chain-info source** per wallet: a malicious or compromised
   endpoint can mislead (not steal). Multi-endpoint cross-checking and BIP-157
   client-side filtering are candidate mitigations.
4. **Owner-side Keychain read does not require biometrics** (only device
   unlock) so that background sync can operate; the reveal flow does. An
   attacker with an *unlocked* phone can open the app and spend on signet.
   A biometric gate on spend is planned before any mainnet consideration.
5. **The heir experience depends on the Recovery Kit surviving** with the
   estate documents; the app cannot help if both kit and repo knowledge are
   lost (though any descriptor-literate person can reconstruct it from the
   two seeds + delay).
6. **bdk-ffi binary distribution** (see §8).
7. **Denial-of-inheritance by fee spikes**: a claim during extreme fee
   markets could be expensive; the claim UI uses live estimates but there is
   no CPFP/RBF flow for a stuck claim yet.

## 11. Reporting

Please report vulnerabilities per [SECURITY.md](SECURITY.md) — privately,
via GitHub Security Advisories on `far1z/heirloom-ios`. Do not open public
issues for security reports.
