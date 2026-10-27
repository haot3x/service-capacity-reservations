# Local Prototype Results

Author: Ted (@haot3x)
Date: 2026-10-23

The ERC-1155 + ERC-2135 baseline builds and passes its local test suite. Two booking entry points share inventory and a common escrow implementation. This is implementation evidence for the chosen application design, not evidence of independent interoperability or a new ERC's necessity.

## Recorded run

Command: `bash scripts/check.sh`, with `FORGE_BIN` selecting the native Forge executable.

| Check | Result |
|---|---|
| Locked npm installation with install scripts disabled | Passed |
| `forge fmt --check` | Passed |
| Solidity 0.8.26 build, Cancun, optimizer 200 | Passed |
| Unit/integration tests, including one fuzz test | 30 passed; 0 failed |
| Two-market quantity fuzzing | 256 cases |
| Stateful invariant test | Passed: 128 sequences, depth 64, 8,192 handler calls |
| Final total | 31 passed; 0 failed; 0 skipped |
| Fuzz seed | `0x20261023` |
| Forge | 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8` |
| OpenZeppelin Contracts | 5.4.0, locked npm dependency |

The full output is in [evidence/local-check.txt](./evidence/local-check.txt). [evidence/SHA256SUMS](./evidence/SHA256SUMS) identifies the source, tests, examples, tooling, and dependency lock used for this result. Verify it from the project root with `shasum -a 256 -c evidence/SHA256SUMS`.

The invariant handler catches expected application reverts and skips inapplicable actions. Its reported zero handler reverts does **not** mean all 8,192 attempted actions succeeded. Checks compare ledger counters with reservation states, token receipt balances, historical successful admissions, provider payments, and unpaid escrow obligations. After every generated sequence, all remaining recoverable orders must close after their deadlines with zero unpaid escrow liability.

## Observed demo

| Action | Observed outcome |
|---|---|
| Direct buyer confirms six reports | Four units remain |
| Signed request attempts five more | Reverts; signed nonce remains unused |
| Signed request confirms four | Zero units remain |
| Provider admits both orders in the window | Ten units permanently consumed |
| Buyer accepts the six-report result | Provider receives 600 raw test-token units |
| Four-report order times out | Original buyer receives full refund |
| Check inventory after both outcomes | Consumed remains ten; free inventory remains zero |

Other tested paths include exact deadline boundaries, duplicate claims and consumption, wrong actor/adapter, signature alteration/replay and domain separation, ERC-1271 holds, allowance failure, fee/false-return token failures, payment callback reentrancy, direct-release recovery, third-party expiry, incompatible order fields, and rollback when order admission fails after consumption.

Tests check ERC-165 IDs and actual ERC-1155 receipt-burn and ERC-2135 consumption events. They do not constitute a complete external standards-conformance audit.

## Build observations

| Production contract | Runtime bytes |
|---|---:|
| CapacityReservations | 13,494 |
| DirectBookingMarket | 8,798 |
| SignedBookingMarket | 11,300 |

All three are below the configured EVM runtime code-size limit. Forge lint reports timestamp-comparison warnings and an intentional test-helper bytes-to-selector cast. Deadlines deliberately use execution-time block timestamps and exact-boundary tests; the helper checks at least four return bytes before reading the error selector. The run is passing, not warning-free.

## Remaining validation

- No deployed contracts, real payments, report execution, or live Finch marketplace integration.
- No independently implemented market adapter, external audit, or proof of physical service capacity.
- No implementation of the alternative ERC-5006/non-token baselines or ERC-8183/8414/8448 integrations.
- No anti-squatting policy; free repeated holds remain a known product limitation.
- GitHub Actions is configured locally, but remote CI and public publication have not occurred.

The next implementation milestone should connect a separate order system and identify the smallest shared booking and recovery semantics it actually needs.
