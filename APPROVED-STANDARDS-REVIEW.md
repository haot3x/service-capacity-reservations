# Service Capacity Reservations: Existing Standards Review

Author: Ted (@haot3x)
Checked: 2026-10-23
Status: Research supplement; baseline A implemented locally; no new ERC submission

## Finding

There is substantial overlap with Final ERCs. The business product remains feasible, but limited inventory, time-limited rights, and one-time consumption are not new standards primitives.

The strongest baseline is an application composed from ERC-1155 and ERC-2135, with pool configuration, booking states, order bindings, and escrow policy supplied by application code. ERC-5006 is the closest quantity-based rental-rights interface and should be evaluated as an alternative. A new ERC is justified only if independent integrations need a shared additional reservation profile or interface.

No unavoidable conflict is identified at the design level. A separate registry can coexist with existing standards. Claiming conformance while changing an existing interface's events, ownership, expiry, or consumption semantics would create incompatibility. The local prototype reuses the ERC-2135 ABI and ERC-1155 implementation; custom booking APIs remain experimental. Tests provide limited implementation evidence, not formal compatibility certification.

## Approval and evidence boundary

The primary comparison uses **Final** standards. Documents merged into the official repository as **Draft** are listed separately; repository inclusion is not finalization. A numbered but open PR is not counted as approved.

Official `ethereum/ERCs` master snapshot: `6b7a48ffa791e30ceee94d869b5eae9521fe158f`, committed 2026-10-22 20:35:44 UTC. Status frontmatter was fetched at this exact commit. Primary official EIP pages and GitHub PR state were also checked on 2026-10-23. This is a targeted relevance review, not an exhaustive audit of every ERC.

Snapshot: https://github.com/ethereum/ERCs/tree/6b7a48ffa791e30ceee94d869b5eae9521fe158f/ERCS

Process definitions: https://eips.ethereum.org/EIPS/eip-1

## Final standards with meaningful overlap

| Standard | Status | Existing coverage | Consequence for the proposal | Raw URL |
|---|---|---|---|---|
| ERC-1155: Multi Token Standard | Final | Token types, per-account quantities, transfers | A type can represent a provider/service/window. A capped implementation can track ten units without double-selling them; a fixed supply is application policy, not required by ERC-1155. | https://eips.ethereum.org/EIPS/eip-1155 |
| ERC-2135: Consumable Interface | Final | Quantity-aware consumption, consumability queries, events; conditions and authority remain application-defined | Strong direct overlap with consuming service admissions. Reuse or map it before defining another consumption primitive. Holds and service-order bindings are not standardized here. | https://eips.ethereum.org/EIPS/eip-2135 |
| ERC-5006: Rental NFT, NFT User Extension | Final | Owner, user, quantity, expiry, usable/frozen balances, and user records over ERC-1155 | Strong overlap with service-use rights. Order binding and permanent use of daily quota require additional semantics; an extension may suffice. | https://eips.ethereum.org/EIPS/eip-5006 |
| ERC-4907: Rental NFT | Final | User/owner separation and expiry over ERC-721 | Can represent the user of an individual service slot; no shared quantity-pool or funded booking lifecycle. | https://eips.ethereum.org/EIPS/eip-4907 |
| ERC-5007: Time NFT | Final | Start/end time reads; optional interval splitting/merging | Adding a time window to a service token is already covered. | https://eips.ethereum.org/EIPS/eip-5007 |
| ERC-3525: Semi-Fungible Token | Final | Token identity, fungibility groups, quantities, value transfers | Alternative representation for uniquely identified bookings with multiple units. A SLOT is a fungibility group, not automatically a scheduling slot. | https://eips.ethereum.org/EIPS/eip-3525 |
| ERC-7818: Expirable ERC-20 | Final | Epoch-based expiring balances/transfers; prepaid service credits are an explicit use case | An expiring service-credit token alone is not a new standardization gap. | https://eips.ethereum.org/EIPS/eip-7818 |
| ERC-7858: Expirable NFTs and SBTs | Final | Validity intervals, expiry queries, optional epochs | Existing basis for expiring service passes. Expired NFTs remain transferable in its NFT profile, so ownership does not prove current entitlement. | https://eips.ethereum.org/EIPS/eip-7858 |
| ERC-5507: Refundable Tokens | Final | Refundable initial token purchases, refund windows, escrowed proceeds | Refundable service-token sales overlap. Task acceptance and unused-booking expiry still need explicit policy. | https://eips.ethereum.org/EIPS/eip-5507 |
| ERC-5528: Refundable Fungible Token | Final | Escrowed seller/buyer token exchange, success and refund paths | Possible settlement building block, not a shared report-work inventory interface. | https://eips.ethereum.org/EIPS/eip-5528 |
| ERC-4400: EIP-721 Consumable Extension | Final | An NFT consumer role | Despite its title, this is not the quantity-consumption interface of ERC-2135. | https://eips.ethereum.org/EIPS/eip-4400 |
| ERC-7432: Non-Fungible Token Roles | Final | Expiring roles, role data, revocability, NFT locking | Useful delegated-utility primitive; roles alone do not specify booking stock or redemption. | https://eips.ethereum.org/EIPS/eip-7432 |
| ERC-5679: Token Minting and Burning | Final | Mint/burn APIs and supply-change events | Issuing and burning service credits are already expressible. A per-pool mint cap remains application policy. | https://eips.ethereum.org/EIPS/eip-5679 |

ERC-20, ERC-165, and ERC-721 are also Final foundations. ERC-7578 is Final but concerns physical-asset disclosure/redemption metadata, not a report-service reservation lifecycle.

## Other proposal statuses, kept separate

| Proposal | Verified status | Treatment | Raw URL |
|---|---|---|---|
| ERC-8183: Agentic Commerce | Official master, Draft | Potential order/escrow integration, not Final | https://eips.ethereum.org/EIPS/eip-8183 |
| ERC-8436: Agent Collective Decision Framework | Official master, Draft | Optional decision policy, not Final | https://eips.ethereum.org/EIPS/eip-8436 |
| ERC-8444: Agentic Resource Discovery | Official master, Draft | Optional discovery, not Final | https://eips.ethereum.org/EIPS/eip-8444 |
| ERC-7589: Semi-Fungible Token Roles | Official master, Draft | Close quantity/role precedent, not Final | https://eips.ethereum.org/EIPS/eip-7589 |
| ERC-6932: Subscription-Based Token | Official master, Draft | Subscription precedent, not Final | https://eips.ethereum.org/EIPS/eip-6932 |
| ERC-5187, ERC-2615, ERC-5334, ERC-5501, ERC-5643 | Official master, Stagnant | Historical prior art; not Final | https://github.com/ethereum/ERCs/tree/6b7a48ffa791e30ceee94d869b5eae9521fe158f/ERCS |
| ERC-8338: Token-Bound Executable Skills | PR #1879 open; not merged | Future composition only | https://github.com/ethereum/ERCs/pull/1879 |
| ERC-8414: Token-Bound Task Tenders | PR #2005 open; not merged | Future composition only | https://github.com/ethereum/ERCs/pull/2005 |
| ERC-8409: Signed Service Payment Quotes | PR #1990 open; not merged | Future composition only | https://github.com/ethereum/ERCs/pull/1990 |
| ERC-8448: Agent Service Order Amendments | PR #2082 open; not merged | Our proposal, not an approved or Final dependency | https://github.com/ethereum/ERCs/pull/2082 |

## Existing-standard baseline

A plausible application uses a fixed issuance of ten ERC-1155 units for a provider/service/window, under immutable mint-cap rules. A booking contract escrows allocated inventory. Service admission consumes the allocation through ERC-2135 semantics. Used units are not reminted; cancellation returns only unconsumed inventory under the agreed policy.

The first six units and the next five cannot both be sold from the same finite inventory. That is ordinary token accounting plus custody and issuance controls, not a new ERC feature. The markets must use the same authoritative inventory. Separate pools, extra minting, or outside sales can still overpromise real-world resources.

Short holds, buyer authorization, confirmation, admission-window checks, and order/escrow binding remain application code. Existing extensibility makes that code possible; it does not mean different implementations already interpret it identically.

Alternatively, a non-token registry could expose ERC-2135-compatible consumption without making reservation records ERC-1155 tokens. ERC-2135's rationale explicitly permits other asset models. Its ABI, view, events, and ERC-165 requirements still apply. The ERC-1155 baseline is now implemented locally; the non-token alternative is not.

## Compatibility hazards to address

### Rental release versus permanent consumption

The ERC-5006 reference implementation returns underlying tokens to the owner when a user record is deleted. Applying that behavior to completed report admissions could make the day's used quota saleable again. A service adapter needs permanent-consumption accounting or destruction of the consumed entitlement. This is an additional service rule, not a rental-standard defect.

That reference also permits the owner or approved operator to delete a record before expiry. Our proposal prohibits unilateral provider cancellation of confirmed bookings. A 5006-based implementation therefore needs custody and authorization arrangements that preserve the booking commitment; it must not assume the rental interface alone makes a confirmed reservation irrevocable.

Source: https://github.com/ethereum/ERCs/blob/6b7a48ffa791e30ceee94d869b5eae9521fe158f/assets/erc-5006/contracts/ERC5006.sol

### Consumption conformance

A method merely named `consume` is not ERC-2135 conformance. The ABI, consumability view, consumption event, and interface detection must match. When the compliant contract is also an ERC-721/ERC-1155 token, consumption requires the specified burn-style transfer event; accounting must remain consistent with it.

The profile must map reservation IDs unambiguously to asset IDs, validate the consumer and bound order, and reject partial consumption if unsupported. A read-time eligibility result does not lock state against later competing transactions.

### Time boundaries and cleanup

Clock-based validity reads do not require an automatic state-writing transaction. Our cleanup transaction updates aggregate counters and enables recovery; this is different from merely reporting an expired right.

The ERC-5006 reference counts usage as valid at the expiry timestamp itself; our proposed lifecycle uses half-open deadlines. Any wrapper must specify and test the translation rather than silently equating both. Existing interfaces retain their own documented semantics.

### Transfer and beneficiary

The proposed registry fixes the beneficiary and order. A tokenized version must explicitly define how transfer affects redemption and refund authority, or keep token inventory in custody while bookings remain non-transferable. It cannot claim that token ownership and booking assignment are automatically the same. ERC-7858's expired-NFT transferability illustrates why possession alone does not establish a current service right.

### Refund and settlement

A refundable-token interface and a service escrow must not create two payout paths for the same obligation. Refunds and provider settlement need one authoritative terminal account of what has been paid. Combining standard interfaces does not supply that invariant by itself.

## Narrower candidate contribution

The potential new contribution is a **service-reservation lifecycle and order-binding profile** through which independent markets agree on:

1. The exact pool, unit definition, time window, beneficiary, and amount held.
2. The transition from hold to confirmed booking, atomically associated with a funded order where supported.
3. Which consumer and order may redeem the booking, reusing consumption interfaces where suitable.
4. Which outcomes release unused inventory and which permanently consume the window's quota.
5. How another integration identifies booking state and the responsible refund/settlement contract.

This does not require inventing a new token, expiry mechanism, rental interface, consumption primitive, or escrow standard. Business-specific pricing and report-quality judgments remain separate.

No reviewed Final standard alone normatively specifies the full combination. That does not prove a new ERC is necessary: a documented composition profile may be sufficient.

## Updated recommendation

Proceed with the product experiment and compare:

- **Baseline A:** ERC-1155 inventory, ERC-2135 consumption, and a small booking/order adapter.
- **Baseline B:** ERC-5006 quantity rights with explicit permanent-consumption accounting and the same booking behavior.
- **Optional C:** the original non-token reservation registry exposing or adapting ERC-2135.

Compare custom rules, repeated adapter logic, event/read interoperability, and recovery across two markets. If the difference is only a Finch-specific workflow, ship an application. If independent implementations need identical additional rules, propose a narrow companion profile or extension with conformance vectors.

Implementation update: baseline A is implemented under `src/`, with tests recorded in [RESULTS.md](./RESULTS.md). Pool IDs represent available inventory and distinct reservation IDs represent custodial receipts; cancellation recycles only unused units and consumption burns receipts permanently. The two entry points share escrow code and are not independent integrations. Baselines B and C remain analyzed alternatives. No deployment or compatibility certification is claimed.

An independent document review checked the pinned specifications and status distinctions and found no material inaccuracies. Its additional note about early owner/operator deletion under the 5006 reference is incorporated above. This review does not replace implementation and conformance tests.

## ASF integration follow-up (2026-10-26)

The prototype now integrates the actual ASF reference registries pinned to commit `64c2e27f2bda90721938327bb08751603a95a459`. ASF is treated as an experimental integration target, not a Final dependency or an assigned ERC number. This addition does not reclassify any proposal in the dated review above. The local action policy, limitations and results are documented in [ASF-INTEGRATION.md](./ASF-INTEGRATION.md).

Pinned source: https://github.com/garyyang-finchip/agent-safety-framework/tree/64c2e27f2bda90721938327bb08751603a95a459
