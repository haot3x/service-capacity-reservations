# Tender admission and scarce capacity

Author: Ted (@haot3x). Test-only composition experiment, 2026-11-01.

The [ERC-8469 author's response](https://ethereum-magicians.org/t/erc-8469-sealed-bid-award-mechanism-for-task-tenders/29814/22) separates an executable award from later fulfillment. If execution requires a scarce service slot, it must already be reserved before accepting the bidder's commitment. A winning reservation should become part of target accounting without returning to free inventory.

`test/TenderAdmission.t.sol` turns that boundary into twelve local tests against the actual `CapacityReservations` ledger. The production ledger and market contracts are unchanged. Two test admission contracts represent two overlapping tenders for the same provider's single research-report slot.

## Modeled lifecycle

| Step | Capacity accounting |
| --- | --- |
| First provider commitment | Reserve one unit atomically before marking the commitment admitted: free 0, held 1 |
| Second overlapping commitment | Revert before storing its commitment; no second reservation or accepted bid |
| First tender loses or becomes void | Release its hold only after a final modeled outcome; another tender may admit |
| First tender wins | Retain the held unit while execution is pending |
| Bind winner to target | Target records the reservation and the ledger confirms that same reservation in one transaction: free 0, confirmed 1 |
| Target write or funding check fails | Both writes revert; the original hold survives for retry before its deadline |
| Execution deadline passes before binding | The hold can expire, and the harness refuses late execution or a new winning outcome |
| Successfully bound reservation outlives the bid deadline | It remains confirmed through the service interval; it cannot expire before the interval ends |

The committed request binds the chain, admission contract, pool, provider, target contract, task content, quantity, interval and bid commitment. The target and its provider/quantity/interval are fixed; a changed task content hash prevents the old reservation from executing. The order identifier binds the target and content. The ledger's existing order view continues to check provider, beneficiary, quantity, interval, service and terms.

The admission contract is the custodial beneficiary in this fixture. That prevents the bidder from using the ledger's beneficiary cancellation route while its commitment is live. The target records the same reservation, while its adapter remains the order-view contract; this is an atomic binding, not an ERC-1155 transfer or a change of adapter ownership.

## Run

```sh
forge test --match-contract TenderAdmissionTest -vv
```

The full `bash scripts/check.sh` includes these tests. Twelve cases cover competing admissions, persistent winner capacity, losing/void release, premature/duplicate release, execution replay, failed funding and target writes, task-content changes, bidder cancellation, expired holds, late finalization and the modeled caller roles.

A negative control removes the reserve call from admission. The second-tender test then fails because both commitments can be accepted. The original source was restored before the full run.

## What is mocked

- A controller supplies final outcomes. No sealed-bid award engine, reveal phase, bidder-cap enforcement, bond or auction proof is implemented or executed.
- `TenderTargetHarness` mocks funding with a boolean and target binding with a stored reservation ID. This is not real payment escrow or an ERC-8183/8414 order contract. Its unrestricted setters are test controls, not public application APIs.
- The model permits one bidder commitment per tender and shares one provider pool. It does not establish physical service capacity, cross-pool exclusivity, anti-Sybil admission, fair access, anti-squatting policy, or truthfulness across concurrent auctions.
- A real integration must authenticate the award outcome and target state, align bid/reveal/execution deadlines with the hold lifetime, and define failure/refund remedies. The fixture rejects execution once the hold deadline arrives; it does not promise an award can execute indefinitely.

The next integration step is to replace the outcome and target harnesses with independently implemented contracts. This evidence supports an admission/reservation extension boundary, not a new `integrationProfile` value or an implemented ERC-8469 extension.
