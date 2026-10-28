# ASF and Service Capacity Reservations

Author: Ted (@haot3x)
Date: 2026-10-28

The local capacity prototype now has an optional ASF-guarded market. It uses the actual pinned ASF specification and binding registries to gate new commitments and result submission. Existing refund and settlement rights remain governed by the original order. This is a consumer integration experiment, not a new ERC or a claim that ASF has reached Final status.

## Version boundary

This snapshot pins revision 7 at commit `a76071c0e0ab76c296a0eb878dee1365ce5a78bc`. The compiled binding-registry interface ID is `0xcff7f826`, checked against the actual registry in the integration suite. No Sepolia deployment is claimed here.

Gary confirmed the separation of provider safety controls and pre-existing buyer escrow rights in [the discussion](https://ethereum-magicians.org/t/erc-8468-agent-safety-framework-asf/30073/15).

The local profile advances to `x:finch:capacity-safety@2`, with new canonical specification and parameter commitments. Any standing stop by the named guardian closes our optional delivery continuation, including an essential-only stop. `StoppedByIntervener` is never an accepted continuation reason. Because revision 7 evaluates a suspended leaf before standing stops, the consumer also queries `stopOf` independently before allowing continuation. A stop-query failure denies continuation. This is our stricter consumer policy, not a change to the upstream evaluator.

## What is connected

`ASFCapacityMarket` extends the direct booking adapter. A guarded pool must name this contract as its **only** adapter; the provider permanently selects one safety binding before any hold can be created. This prevents an unguarded adapter or a replacement binding from bypassing a stop on that pool. Other pools and off-chain work remain outside the guarantee.

The consumer fixes specification version 1, its canonical document hash, the required profile, parameter hash, and guardian. Every ancestor must retain the same provider, pool scope, specification, parameters and authority reference. The guardian must hold suspend/resume rights on every record, and no other account may hold a resume right. Additional stop rights do not grant permission to resume.

The authority reference is checked against the actual pool provider, chain, registry and pool ID. It is not accepted as a self-authenticating claim. The scope also includes the market address. Only the trusted, pinned reference registries are supported by this experiment; the consumer does not authenticate arbitrary registry implementations merely because they expose the same interface.

Source: https://github.com/garyyang-finchip/agent-safety-framework/tree/a76071c0e0ab76c296a0eb878dee1365ce5a78bc

Discussion: https://ethereum-magicians.org/t/30073

## Action policy

These are the semantics of local profile `x:finch:capacity-safety@2`, not universal meanings assigned to every ASF consumer. All original actor, order-state and deadline checks still apply.

| Action | Satisfied binding | Suspended: union is exactly 4 or 5 | Other suspension, expiry, termination or unknown |
|---|---|---|---|
| Create a hold | Allowed | Denied | Denied |
| Confirm and fund a hold | Allowed | Denied | Denied |
| Admit work and consume quota | Allowed | Denied | Denied |
| Submit a result for already-admitted work | Allowed | Allowed only with no standing guardian stop and all suspended `responseRef` values zero | Denied |
| Cancel or release unused reservation | Original order/ledger rules | Original order/ledger rules | Original order/ledger rules |
| Expire and recover eligible escrow | Original deadlines and buyer recipient | Same | Same |
| Accept or reject an already-submitted result | Original buyer authority and deadline | Same | Same |

`4` is `ESSENTIAL_ONLY`; `5` adds `NO_NEW_RISK`. All other suspension sets close submission, including `DERISK_ONLY`, `SHRINK` and any set containing `FULL_STOP`. This narrow profile treats every suspended state as closed to new commitments. An essential-only permission cannot create an admission or submit an unadmitted order.

Restrictions are taken from the registry's evaluated result, including ancestor unions, rather than from the leaf's local flags. An unknown/reverting/malformed check cannot authorize an operation. Expiry and termination do not become continuation merely because another record still has essential-only flags. A nonzero response document might impose additional requirements: because this prototype does not interpret it, continuation is denied.

The provider's safety binding covers new commitments and result submission. It does not grant the guardian custody of buyer funds or authority to accept a result. Buyer cancellation, third-party cleanup, deadline refunds and buyer evaluation are **explicitly separate, pre-existing order rights**. Full stop therefore blocks covered provider operations without silently rewriting these rights. A different application that also wants to suspend asset settlement would need separately agreed scope and recovery rules.

Refunds after admission never reopen consumed capacity. Resume does not extend booking, admission or settlement deadlines.

## Implementation details that matter

1. `CapacityReservations.adapterCount` exposes the immutable adapter count, allowing guarded setup to reject mixed entry points.
2. `MarketEscrow` adds default-empty policy hooks for holds, confirmation, admission and submission. The original direct and signed adapters retain their behavior.
3. Confirmation checks safety both before and after the payment-token transfer. A token callback can otherwise change an external safety registry after the first check. If the second check fails, payment, order changes and callback changes all revert atomically.
4. The pinned leaf cannot be swapped for a newly adopted binding, including after termination. Recovery uses the original order paths; a new service pool is a different scope, not a resumption of old commitments. A standing stop is keyed without scope and can still block another pool using the same adopter, subject, specification and guardian. Merely choosing a new pool does not clear it.
5. ASF's clause evaluates the selected leaf; the local consumer separately verifies ancestor resume holders. A valid leaf clause alone does not establish our stronger whole-chain guardian policy. The regression test demonstrates this **consumer-policy boundary**, not a claimed defect in ASF's documented clause semantics.

## Documents and reproduction

The specification, profile descriptor and fixed parameter document are in [examples/asf](./examples/asf). Readable and canonical byte representations are committed. They use only ASCII strings and safe integers; the offline verifier supports that restricted JCS-compatible subset, not arbitrary JCS documents. Solidity tests compare compiled specification and parameter commitments with their exact canonical bytes.

```sh
bash scripts/check.sh
bash scripts/demo-asf.sh
uv run --with jsonschema==4.26.0 python scripts/validate-asf-documents.py
```

The first command needs Python 3, Node/npm and native Foundry 1.7.1. `FORGE_BIN` can select the Forge executable. The last command additionally uses `uv` to run the pinned JSON Schema validator; all schema references resolve to the vendored local schemas. Dependency provenance and integrity checks are described in [vendor/asf/README.md](./vendor/asf/README.md).

The 28 ASF integration tests include two 256-run fuzz tests over adopter suspension masks and standing guardian stop masks; fresh bindings after termination; a suspended leaf masking a terminated sibling's standing stop; named-lifter recovery; unavailable stop queries; parent/leaf unions; exact expiry; termination; unsupported profiles; authority mismatches; immutable binding selection; parent resume-holder closure; unknown/reverting/malformed checks; response-document refusal; callback-triggered suspension; cancellation; third-party recovery; and buyer-only settlement. The real ASF registries execute the normal lifecycle. Explicit mocks are used to inject unavailable or malformed registry responses; the payment asset is a local test token.

A targeted mutation removes the independent standing-stop guard. The terminated-sibling regression must fail under that mutation. Earlier revision-4 checks also exercised removal of the post-transfer and ancestor resume-holder guards; those historical results are not a rerun against this snapshot.

## What this proves, and what remains

This is evidence that a concrete service-capacity consumer can distinguish stopped admission, narrowly permitted continuation and independent escrow recovery. It does not prove physical capacity, work quality, off-chain dispatch deduplication or consensus on this profile.

There is no deployment, real payment, external audit, independently implemented order adapter, or execution of ASF's full upstream suite. The existing stateful inventory/escrow invariant uses the original adapters; ASF coverage consists of the separate integration and flags-fuzz tests. Recorded results and build sizes are in [RESULTS.md](./RESULTS.md).

The code is published at https://github.com/haot3x/service-capacity-reservations. The revision-7 fixture makes the confirmed buyer-rights boundary executable. It also shows why a consumer that grants limited continuation must consider standing stops separately from the first failure reason.
