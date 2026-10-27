# Service Capacity Reservations

Author: Ted (@haot3x)

A local Solidity prototype for selling ten research-report admissions through two markets backed by the same inventory. It composes ERC-1155 custody and ERC-2135 consumption with booking records and an experimental paid order lifecycle. An optional ASF-guarded market now tests safety suspension, limited delivery continuation and independent escrow recovery using the pinned upstream reference registries.

**Experimental reference code. No chain deployment, dedicated Magicians topic, new ERC number, or independent security audit is included.**

Repository: https://github.com/haot3x/service-capacity-reservations

ASF compatibility is pinned to **revision 4**. Upstream revision 6 adds standing stops and changes the binding-registry interface; this snapshot does not claim revision-6 compatibility. See [the version boundary](./ASF-INTEGRATION.md#version-boundary).

## Run

Prerequisites: Python 3, Node.js/npm and Foundry **v1.7.1**. Solidity **0.8.26** and Cancun are configured in `foundry.toml`; OpenZeppelin Contracts **5.4.0** is pinned in `package-lock.json`.

```sh
bash scripts/check.sh
bash scripts/demo.sh
bash scripts/demo-asf.sh
```

`check.sh` verifies the pinned ASF dependency and canonical policy documents, installs the locked npm dependency with install scripts disabled, checks formatting, builds production contracts, and runs all tests with seed `0x20261026`. `demo.sh` runs the two-market scenario and `demo-asf.sh` runs suspension/recovery after dependencies are installed. To select a native Forge executable outside `PATH`, set `FORGE_BIN=/absolute/path/to/forge`.

The demo is a local EVM test. It uses no wallet key, RPC endpoint, real service, or real payment asset. Its synthetic timestamps and raw test-token amounts are not a live commercial offer.

Expected demo:

1. Direct market confirms six admissions; four remain.
2. Signed market attempts five; the transaction reverts and its nonce remains unused.
3. Signed market confirms four; no inventory remains.
4. Provider admits both orders during the window, consuming all ten units.
5. Buyer accepts the six-report order, paying the provider 600 raw token units.
6. The four-report order times out and refunds its buyer. Consumed quota remains ten.

See [RESULTS.md](./RESULTS.md) for recorded checks and [evidence/local-check.txt](./evidence/local-check.txt) for the run output. The same checks run in [GitHub Actions](https://github.com/haot3x/service-capacity-reservations/actions/workflows/test.yml); see that page for the current remote result. The current run passes **55 tests**, including **24 ASF integration tests**. See [ASF-INTEGRATION.md](./ASF-INTEGRATION.md) for the action matrix, authority boundaries and optional JSON Schema validation command.

## Components

| Component | Responsibility |
|---|---|
| `CapacityReservations` | Immutable pools, adapter permissions, held/confirmed/consumed counts, custodial receipts, admission checks |
| `DirectBookingMarket` | Buyer creates a hold through a direct transaction |
| `SignedBookingMarket` | Anyone relays an EIP-712 hold signed by the buyer; supports EOA and ERC-1271 signatures |
| `MarketEscrow` | Shared experimental escrow: payment, confirmation, admission, result commitment, buyer acceptance/rejection, refund |
| `IReservationOrder` | Application-specific read interface exposing the bound funded order |
| `ASFCapacityMarket` | Optional fixed-binding ASF guard for new commitments and result submission; requires a pool with this sole adapter |
| `vendor/asf` | Unmodified revision-4 reference registries, types, interfaces, key helpers and schemas |

The adapters have different booking entry points but share the same escrow implementation. They demonstrate two integration paths, **not two independent implementations or real marketplace integrations**. Signed holds do not authorize payment; the buyer must separately confirm and fund the order. The ASF variant is a separate one-adapter pool configuration, so a second unguarded adapter cannot bypass its policy.

## Token and reservation semantics

Pool IDs and reservation IDs share one ERC-1155 ID namespace. At pool creation, all capacity units are minted to the registry itself.

| Transition | Pool inventory token | Reservation receipt token | Accounting |
|---|---|---|---|
| Hold `n` units | Burn `n` available units | Mint `n` units under a new reservation ID | Increase held |
| Confirm | No change | No change | Held becomes confirmed |
| Cancel / expire unused | Remint `n` available units | Burn `n` receipt units | Remove held or confirmed |
| Consume | No remint | Burn `n` receipt units | Confirmed becomes permanently consumed |

The conversion never increases aggregate unconsumed capacity. Consumers do not own bearer tokens: receipts remain in registry custody, while the reservation fixes the service beneficiary. The registry does not grant external token approvals. No resale, splitting, or partial consumption is implemented.

ERC-2135's `assetId` is the **reservation ID**, and `consumer` is the **beneficiary**. `consume` requires the creating adapter and `data = abi.encode(orderContract, orderId)`. A true `isConsumableBy` result describes current asset eligibility; it does not authorize its caller to consume or lock availability. Consumption emits both the ERC-2135 event and a real ERC-1155 receipt burn.

The tested accounting properties are:

```text
pool balance + held + confirmed + consumed = configured capacity
aggregate ERC-1155 supply = aggregate configured capacity - aggregate consumed
market token balance >= unpaid escrow obligations
```

Tests use exact balances without donations. A direct token donation can leave surplus in a market and does not create another order or liability; this prototype has no surplus withdrawal function.

`availability` returns stored free inventory and a separate `bookingOpen` flag. Expired records remain counted until a caller performs cleanup. Once booking closes, a positive stored balance does not make new bookings valid.

## Booking and payment policy

- A provider creates a pool as `msg.sender`, chooses immutable service/terms hashes, capacity, admission window, maximum hold duration, and up to sixteen trusted adapters.
- Each market has a provider-configured, immutable price and settlement deadline for the pool. Confirmation fully funds `units * unitPrice` in that market's configured token.
- Only the original adapter confirms a hold. The ledger checks provider, buyer, pool, units, service/terms hashes, admission window, order ID, and funded status, then checks them again before consumption.
- Buyer cancellation is allowed before `windowStart`; admission is allowed in `[windowStart, windowEnd)`. Hold validity and settlement acceptance also use exclusive deadlines, evaluated at transaction execution.
- Direct ledger release and third-party expiry preserve a one-time refund path. Any caller can trigger recovery, but payment always goes to the original buyer.
- The provider submits a result hash. The buyer alone evaluates it: acceptance pays the provider, rejection refunds the buyer, and unresolved admitted/submitted orders refund after the settlement deadline. These are demonstration terms, not neutral arbitration.
- A consumed booking remains consumed after acceptance, rejection, or timeout refund. Financial settlement does not replenish work-admission capacity.

[Service definition](./examples/research-report-v1.json) bounds the example report and [booking terms](./examples/booking-terms-v1.json) describe settlement. Tests commit the exact UTF-8 file bytes using Keccak-256. These hashes bind documents, not their correctness. Input validation, report generation, delivery, and the dispatcher's order-level deduplication remain off-chain and are not implemented here.

## Standards and the remaining question

The [standards review](./APPROVED-STANDARDS-REVIEW.md) distinguishes Final standards from merged drafts and open PRs. This implementation selects the ERC-1155 + ERC-2135 baseline. ERC-5006 and a non-token registry are analyzed alternatives, not additional implemented baselines.

Finite stock, expiries, and consumption already have standards precedents. This code does not establish a need for a new ERC. The possible contribution is a narrow common interpretation of booking state, authoritative order binding, and recovery across independent integrations. The custom booking and order-read APIs are experimental and have no assigned ERC interface ID.

ERC-8183, ERC-8414, and ERC-8448 are potential integration targets; this prototype implements none of their order lifecycles or amendment interfaces.

## Limits relevant to implementation

- The guarantee is scoped to one `(chainId, registry, poolId)`. A provider can create other pools or oversell elsewhere; the ledger cannot prove physical capacity or report quality.
- Authorized adapters are trusted for buyer consent and truthful order state. A contract-code check does not prove honesty, non-upgradeability, or funding. The supplied adapters implement the demonstrated checks; an arbitrary authorized adapter could lie.
- The demo adapters have no booking fee, account quota, or rate limit. A buyer can repeatedly occupy stock with free holds. Short deadlines alone do not solve inventory squatting.
- Escrow is intended for a known exact-transfer token. Balance checks catch the tested fee-on-transfer and false-return cases; they cannot make malicious, rebasing, upgradeable, or blocked-transfer assets reliable. Recoverability assumes the configured token continues to transfer normally.
- The buyer can reject good work or withhold acceptance. A production service needs deliberately chosen evaluation and dispute terms.
- Storage grows with pools, reservations, used requests, and order tombstones. There is no administrative deletion, upgrade path, or emergency withdrawal.

Next useful validation: integrate one genuinely independent order implementation and record which booking/read/recovery rules it needs to share. That evidence should determine whether to publish an application profile or pursue a new ERC.
