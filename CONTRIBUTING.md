# Contributing to Heirloom

Thanks for looking under the hood — that's the point of this project.

## Ground rules

- **Security reports never go in public issues.** Use the process in
  [SECURITY.md](SECURITY.md).
- The core promise is *policy simplicity*: one descriptor,
  `wsh(or_d(pk(owner),and_v(v:pk(heir),older(N))))`. PRs that add spending
  paths, keys, or server dependencies to the core policy will be declined
  unless they come with extraordinary justification and analysis.
- Signet stays the default network. Anything that weakens the mainnet gate
  (`MAINNET_ENABLED`) will be declined until an external audit exists.

## Getting started

```bash
brew install xcodegen
git clone https://github.com/far1z/heirloom-ios && cd heirloom-ios
xcodegen generate
open Heirloom.xcodeproj   # or build from CLI, see TESTING.md
```

The Xcode project is generated — **edit `project.yml`, not the
`.xcodeproj`**, and re-run `xcodegen generate` after adding files.

## Code layout

```
Heirloom/Core/      policy, keys, wallet service, chain client (no UI)
Heirloom/UI/        SwiftUI views, grouped by flow
HeirloomTests/      unit + integration tests (see TESTING.md)
scripts/            regtest harness
```

Conventions: SwiftUI + `@MainActor` manager pattern; BDK blocking calls run
off the main thread via `Task.detached`; every irreversible UI step gets a
`WarningBox`; comments explain *constraints* (consensus rules, BDK quirks),
not narration.

## Tests are the contract

Any change to `Core/` needs a test. If you touch policy, descriptor, or
transaction code, run the regtest lifecycle (`scripts/regtest-up.sh`,
then `RegtestLifecycleTests`) before opening the PR — it is the closest
thing we have to the Bitcoin network's own opinion.

## Commit style

Present-tense summary line; body explains *why*. Group logical changes;
don't mix refactors with behavior changes.
