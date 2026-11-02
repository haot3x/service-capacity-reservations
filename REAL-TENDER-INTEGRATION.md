# Real sealed-bid capacity integration

Author: Ted (@haot3x)

This local experiment runs the actual ERC-8469 `SealedBidTender` and
`PostedPriceAward`, pinned to
`0d615b2e310cdd85d453c8935c1e3bf7a0a41079`, against this repository's actual
`CapacityReservations` and `DirectBookingMarket`. It replaces modeled auction
outcomes and funded flags in the earlier admission experiment with real
commit/reveal/finalize and ERC-20 escrow transitions.

## Flow

1. The buyer chooses a service/window/price template and prefunds `units * price`.
2. Each provider selects its own matching inventory pool. The overridden public
   `commitBid` reserves actual capacity before the upstream core records a bid.
   Any core rejection also rolls back the hold and nonce.
3. The pinned posted-price rule chooses one provider, in commit order, among
   qualifying reveals. The auction quantity is one provider, not the service quantity.
4. Anyone can hand the award to the booking escrow before the service window.
   `settle` transfers the prefund and confirms the **same reservation ID** in one
   transaction. A failed transfer leaves the hold, funds and job unchanged.
5. The provider admits and delivers through the existing booking contract. The
   original buyer accepts or rejects through the router; timeout refunds remain
   permissionless and always return to that buyer.

The router is the reservation beneficiary for custody. Neither the bidder nor
buyer can directly release a live bid hold. Losers and void bids can be released
once the actual tender is final; an expired hold can also be cleaned up through
normal inventory expiry. A confirmed winner can be cancelled by its buyer under
the original pre-window cancellation terms.

## Deliberate boundaries

- The profile is **allocation-only**, with fixed posted price and zero bonds.
  It is not price-binding or execution-binding. Finalization after the service
  window cannot guarantee execution: settlement fails and the buyer can recover
  its prefund, even if nobody finalizes. No new integration profile is proposed.
- An inherited `openTender` call outside the router has no registered job and
  cannot admit a bid through this extension. Use the router's `open` entry point.
- Providers need matching immutable service/terms hashes, interval, price and
  settlement deadline. The content hash binds the chain, router, booking market,
  token, buyer, target ID, service terms, quantity and total price.
- The booking target is our existing application escrow, **not an ERC-8414 task
  kernel**. This demonstrates composition with an independently authored auction,
  not independent implementation of the entire marketplace.
- Inventory guarantees apply only within the same ledger/pool. Physical capacity,
  duplicate pools, quality, bid squatting, payment-token reliability and keeper
  availability remain application assumptions. There is no chain deployment.
- These paths do not add ASF policy checks. ASF coverage remains the separate
  guarded-market integration.

## Evidence

`test/RealTenderCapacity.t.sol` adds 12 cases: paid delivery; competing tenders;
core rejection rollback; no direct admission/release bypass; loser cleanup;
void refund; failed-payment rollback and retry; provider/terms checks; delayed
finalization; buyer cancellation; consumed-capacity timeout; callback reentry.

The full check passes 85 tests. Runtime sizes are 11,619 bytes for the admitted
tender and 10,670 for the router; router initialization is 24,459 bytes. Both
runtime and init code are below the configured EVM limits. Removing the admission
hook causes the competing-tender regression to fail; the original code was restored.

- [Full check](./evidence/2026-11-02-real-tender-check.txt)
- [Admission bypass negative control](./evidence/real-tender-negative-control.txt)
- [Pinned upstream provenance](./vendor/erc8469/README.md)
