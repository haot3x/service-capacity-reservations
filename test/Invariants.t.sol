// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture, TestSupport, MockPaymentToken} from "./TestSupport.sol";
import {CapacityReservations} from "../src/CapacityReservations.sol";
import {DirectBookingMarket} from "../src/DirectBookingMarket.sol";
import {SignedBookingMarket} from "../src/SignedBookingMarket.sol";
import {MarketEscrow} from "../src/MarketEscrow.sol";

/// @dev Calls may be invalid for the current state. Expected reverts are caught; assertions are not.
contract LifecycleHandler is TestSupport {
    CapacityReservations public immutable registry;
    DirectBookingMarket public immutable direct;
    SignedBookingMarket public immutable signedMarket;
    uint256 public immutable pool;
    address public immutable provider;
    address public immutable alice;
    address public immutable bob;
    uint256[] public ids;
    uint256 public successfulCalls;
    uint256 public admittedUnits;
    uint256 public acceptedPayments;
    uint256 private constant BOB_KEY = 0xB0B123;

    constructor(
        CapacityReservations registry_,
        DirectBookingMarket direct_,
        SignedBookingMarket signed_,
        uint256 pool_,
        address provider_,
        address alice_,
        address bob_
    ) {
        registry = registry_;
        direct = direct_;
        signedMarket = signed_;
        pool = pool_;
        provider = provider_;
        alice = alice_;
        bob = bob_;
    }

    function hold(uint8 rawUnits, bool relayed) external {
        uint64 start = registry.getPool(pool).config.windowStart;
        if (block.timestamp >= start) return;
        uint64 until = uint64(block.timestamp + 500);
        if (until > start) until = start;
        uint64 units = uint64(rawUnits % 5 + 1);
        bool ok;
        bytes memory result;
        if (relayed) {
            SignedBookingMarket.HoldRequest memory req =
                SignedBookingMarket.HoldRequest(bob, pool, units, until, signedMarket.nonces(bob), until);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_KEY, signedMarket.holdDigest(req));
            (ok, result) = address(signedMarket)
                .call(abi.encodeCall(signedMarket.holdSigned, (req, abi.encodePacked(r, s, v))));
        } else {
            vm.prank(alice);
            (ok, result) = address(direct).call(abi.encodeCall(direct.hold, (pool, units, until)));
        }
        if (ok) {
            ids.push(abi.decode(result, (uint256)));
            successfulCalls++;
        }
    }

    function confirm(uint256 seed) external {
        _market(seed, MarketEscrow.confirm.selector, false);
    }

    function cancel(uint256 seed) external {
        _market(seed, MarketEscrow.cancel.selector, false);
    }

    function admit(uint256 seed) external {
        _market(seed, MarketEscrow.admit.selector, true);
    }

    function refund(uint256 seed) external {
        _market(seed, MarketEscrow.claimRefund.selector, false);
    }

    function release(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address buyer = registry.getReservation(id).beneficiary;
        vm.prank(buyer);
        (bool ok,) = address(registry).call(abi.encodeCall(registry.release, (id)));
        if (ok) successfulCalls++;
    }

    function expire(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        (bool ok,) = address(registry).call(abi.encodeCall(registry.expire, (id)));
        if (ok) successfulCalls++;
    }

    function finish(uint256 seed, bool accepted) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        CapacityReservations.Reservation memory r = registry.getReservation(id);
        vm.prank(provider);
        (bool ok,) = r.adapter.call(abi.encodeCall(MarketEscrow.submit, (id, keccak256("demo report"))));
        if (ok) successfulCalls++;
        vm.prank(r.beneficiary);
        (ok,) = r.adapter
            .call(
                abi.encodeWithSelector(
                    accepted ? MarketEscrow.accept.selector : MarketEscrow.reject.selector, id
                )
            );
        if (ok) {
            successfulCalls++;
            if (accepted) acceptedPayments += MarketEscrow(r.adapter).getOrder(id).amount;
        }
    }

    function advance(uint16 delta) external {
        vm.warp(block.timestamp + uint256(delta % 4_001));
    }

    function _market(uint256 seed, bytes4 selector, bool byProvider) private {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        CapacityReservations.Reservation memory r = registry.getReservation(id);
        vm.prank(byProvider ? provider : r.beneficiary);
        (bool ok,) = r.adapter.call(abi.encodeWithSelector(selector, id));
        if (ok) {
            successfulCalls++;
            if (selector == MarketEscrow.admit.selector) admittedUnits += r.units;
        }
    }

    function count() external view returns (uint256) {
        return ids.length;
    }
}

contract ReservationInvariants is Fixture {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }
    LifecycleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LifecycleHandler(registry, direct, signedMarket, poolId, PROVIDER, ALICE, bob);
        // Start with funded and unfunded reservations in both markets, then randomize the lifecycle.
        handler.hold(1, false);
        handler.confirm(0);
        handler.hold(1, true);
        handler.confirm(1);
        handler.hold(0, false);
        handler.hold(0, true);
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.hold.selector;
        selectors[1] = handler.confirm.selector;
        selectors[2] = handler.cancel.selector;
        selectors[3] = handler.admit.selector;
        selectors[4] = handler.refund.selector;
        selectors[5] = handler.release.selector;
        selectors[6] = handler.expire.selector;
        selectors[7] = handler.finish.selector;
        selectors[8] = handler.advance.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    function invariant_InventoryReceiptsAndEscrowRemainConserved() public view {
        assertAccounting();
        uint256 held;
        uint256 confirmed;
        uint256 consumed;
        uint256 directDebt;
        uint256 signedDebt;
        for (uint256 i; i < handler.count(); ++i) {
            uint256 id = handler.ids(i);
            CapacityReservations.Reservation memory r = registry.getReservation(id);
            if (r.status == CapacityReservations.Status.Held) held += r.units;
            if (r.status == CapacityReservations.Status.Confirmed) confirmed += r.units;
            if (r.status == CapacityReservations.Status.Consumed) consumed += r.units;
            bool live = r.status == CapacityReservations.Status.Held
                || r.status == CapacityReservations.Status.Confirmed;
            eq(registry.balanceOf(address(registry), id), live ? r.units : 0);
            try MarketEscrow(r.adapter).getOrder(id) returns (MarketEscrow.Order memory order) {
                if (
                    order.status == MarketEscrow.OrderStatus.Funded
                        || order.status == MarketEscrow.OrderStatus.Admitted
                        || order.status == MarketEscrow.OrderStatus.Submitted
                ) {
                    if (r.adapter == address(direct)) directDebt += order.amount;
                    else signedDebt += order.amount;
                }
                if (order.status == MarketEscrow.OrderStatus.Settled) {
                    eq(uint256(r.status), uint256(CapacityReservations.Status.Consumed));
                }
            } catch {}
        }
        CapacityReservations.Pool memory pool = registry.getPool(poolId);
        eq(pool.held, held);
        eq(pool.confirmed, confirmed);
        eq(pool.consumed, consumed);
        eq(consumed, handler.admittedUnits());
        eq(token.balanceOf(PROVIDER), handler.acceptedPayments());
        eq(direct.escrowLiability(), directDebt);
        eq(signedMarket.escrowLiability(), signedDebt);
        eq(
            token.balanceOf(ALICE) + token.balanceOf(bob) + token.balanceOf(PROVIDER)
                + token.balanceOf(address(direct)) + token.balanceOf(address(signedMarket)),
            token.totalSupply()
        );
    }

    /// @dev Every generated sequence must still permit terminal recovery after all deadlines.
    function afterInvariant() public {
        if (block.timestamp < DEADLINE) vm.warp(DEADLINE);
        for (uint256 i; i < handler.count(); ++i) {
            uint256 id = handler.ids(i);
            CapacityReservations.Reservation memory r = registry.getReservation(id);
            if (r.status == CapacityReservations.Status.Held) registry.expire(id);
            try MarketEscrow(r.adapter).getOrder(id) returns (MarketEscrow.Order memory order) {
                if (
                    order.status == MarketEscrow.OrderStatus.Funded
                        || order.status == MarketEscrow.OrderStatus.Admitted
                        || order.status == MarketEscrow.OrderStatus.Submitted
                ) MarketEscrow(r.adapter).claimRefund(id);
            } catch {}
        }
        invariant_InventoryReceiptsAndEscrowRemainConserved();
        eq(direct.escrowLiability(), 0);
        eq(signedMarket.escrowLiability(), 0);
        eq(registry.getPool(poolId).held, 0);
        eq(registry.getPool(poolId).confirmed, 0);
        yes(handler.successfulCalls() >= 6);
    }
}
