# Local Prototype Results

Author: Ted (@haot3x)
Recorded local run: 2026-10-28

The capacity-reservation baseline and the new ASF consumer integration pass **59 local tests**. The ASF tests run the actual revision-7 reference registries, pinned to commit `a76071c0e0ab76c296a0eb878dee1365ce5a78bc`. This is implementation evidence for a local application profile, not independent interoperability, an audit, or approval of a new ERC.

## Recorded run

Command: `bash scripts/check.sh`, with `FORGE_BIN` selecting the native Forge executable.

| Check | Result |
|---|---|
| Vendored dependency integrity | 16 files match the pinned manifest; also compared byte-for-byte to the upstream checkout |
| Canonical policy documents | 3 byte representations match readable JSON; parameters/profile references agree |
| JSON Schema validation, separate recorded command | Specification and profile pass the pinned upstream schemas with jsonschema 4.26.0 |
| Locked npm installation with install scripts disabled | Passed |
| `forge fmt --check` | Passed; vendored source deliberately excluded |
| Solidity 0.8.26 build, Cancun, optimizer 200 | Passed |
| Reservation and signed-hold tests | 30 passed |
| ASF integration tests | 28 passed |
| Fuzz tests | 256 quantity cases, 256 adopter-suspension cases and 256 standing-stop cases |
| Stateful inventory/escrow invariant | Passed: 128 sequences, depth 64, 8,192 handler calls |
| Final total | 59 passed; 0 failed; 0 skipped |
| Fuzz seed | `0x20261026` |
| Targeted mutation checks | Independent stop-query omission caught by the terminated-sibling regression; source restored and that regression passed |
| Forge | 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8` |
| OpenZeppelin Contracts | 5.4.0, locked npm dependency |

Evidence:

- [Full local check](./evidence/local-check.txt)
- [Schema validation](./evidence/asf-schema-check.txt)
- [Revision-7 standing-stop mutation failure](./evidence/asf-stop-mutation-check.txt)
- [Historical revision-4 mutation failures](./evidence/asf-mutation-check.txt)
- [Current source and evidence SHA-256 manifest](./evidence/SHA256SUMS)
- [Historical 2026-10-23 baseline output](./evidence/2026-10-23-baseline/local-check.txt)

Verify the current snapshot from the project root with `shasum -a 256 -c evidence/SHA256SUMS`. The archived baseline manifest identifies the earlier 31-test snapshot and is not a manifest of the current files.

The invariant handler uses the original direct/signed adapters, not the ASF adapter. It catches expected application reverts and skips inapplicable actions; zero handler reverts does **not** mean all attempted actions succeeded. It checks ledger counters, receipt balances, historical admissions, provider payments and unpaid obligations, followed by deadline recovery to zero unpaid liability. ASF coverage is the separate integration and suspension-mask fuzz suite, not a claim of stateful ASF invariant coverage or exhaustive enumeration of all inputs.

## Observed demonstrations

The original two-market demonstration still passes: six direct admissions leave four available, a signed request for five fails, four succeed, and all ten are eventually consumed. Buyer acceptance pays 600 raw test-token units for one order; the other times out and refunds without restoring consumed quota.

The ASF demonstration observes:

| Action | Outcome |
|---|---|
| Suspend parent with `NO_NEW_RISK + DERISK_ONLY` | Covered new commitments stop |
| Buyer cancels a funded, unadmitted order before the window | Buyer receives 100 raw test-token units |
| Guardian resumes, provider admits a separate order | One unit becomes permanently consumed |
| Provider self-suspends parent with `NO_NEW_RISK + ESSENTIAL_ONLY`, with no standing guardian stop | Already-admitted result submission succeeds |
| Add full stop after submission | Further covered provider work stops; buyer retains original evaluation authority |
| Buyer accepts that submitted result | Provider receives 100 raw test-token units; consumed quota remains one |

The action policy and its explicit escrow scope are in [ASF-INTEGRATION.md](./ASF-INTEGRATION.md). The guardian cannot accept an order on the buyer's behalf.

The revision-7 mutation removes `_standingStopAbsent` from the continuation condition. A guardian stops an independent sibling, that sibling is terminated, and the provider self-suspends the pinned leaf with `ESSENTIAL_ONLY`. The registry reports `Suspended` first with flags 4, while the full standing stop survives. Without the consumer's separate query, submission succeeds and the regression fails. Restoring the guard makes the same test pass. This is a consumer-policy regression, not a claimed upstream defect.

The earlier revision-4 mutation log is retained as historical evidence for payment callback and ancestor resume-holder checks. Those two mutations were not rerun in this revision.

## Build observations

| Local production contract | Runtime bytes |
|---|---:|
| CapacityReservations | 13,563 |
| DirectBookingMarket | 8,798 |
| SignedBookingMarket | 11,300 |
| ASFCapacityMarket | 17,082 |

All four are below the configured runtime code-size limit. The base direct/signed adapter sizes remain unchanged. The local test EVM successfully deploys both actual ASF registries; the production build-size table above lists our consumer contracts, not an upstream deployment certification.

Forge lint reports timestamp-comparison warnings and the existing intentional test-helper selector cast. Deadlines use execution-time timestamps and have boundary tests; the helper checks at least four return bytes. The passing run is not warning-free.

## Remaining validation

- No deployed contracts, real payments, report generation or live Finch marketplace integration.
- No independently implemented market adapter, external audit or proof of physical service capacity.
- No interpretation of nonzero ASF response documents; those close suspended delivery continuation.
- No guarantee across other pools, chains or off-chain actions, and no protection against a dishonest substituted registry or unreliable payment token.
- No implementation of ERC-5006/non-token alternatives or ERC-8183/8414/8448 order integrations.
- Free repeated holds still have no anti-squatting policy.
- The recorded run above is local. Public source: https://github.com/haot3x/service-capacity-reservations. Remote results are available in GitHub Actions; they are separate from the archived local log. The complete ASF upstream suite was not replayed.
- Compatibility is limited to the pinned revision-7 commit. Future upstream changes require a new review.

Next: review the tested standing-stop integration with the ASF author, then connect an independently implemented order system before arguing for a new standard.
