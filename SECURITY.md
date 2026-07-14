# Security Policy

## Status

Heirloom is **pre-release, signet-only software**. It has received an
internal self-review ([SECURITY_REVIEW.md](SECURITY_REVIEW.md)) but **no
independent security audit**. Do not use it with real funds. The mainnet
build flag is off and documented as "NOT AUDITED — DO NOT USE WITH REAL
FUNDS".

## Reporting a vulnerability

Please report vulnerabilities **privately** via
[GitHub Security Advisories](https://github.com/far1z/heirloom-ios/security/advisories/new)
on this repository. Do not open public issues or pull requests for security
problems.

What to expect:

- Acknowledgement within 72 hours.
- A fix or public disclosure plan within 90 days (usually much sooner —
  the codebase is small).
- Credit in the release notes if you want it.

## Scope

In scope: anything in this repository — policy/descriptor construction, key
handling, Keychain usage, transaction building, the recovery flow, the
network layer, and the build configuration.

Out of scope: the Bitcoin protocol itself, BDK (report to
[bitcoindevkit](https://github.com/bitcoindevkit/bdk/security)), and the
landing page repo (cosmetic).

## Keys and funds

There is nothing to steal from us: Heirloom is non-custodial, has no
backend, and holds no user keys anywhere. If you believe you've found a way
for anyone other than the owner (anytime) or the heir (after the timelock)
to move funds, that is the highest-severity report possible — please use
the advisory channel above immediately.
