// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestSupport, MockPaymentToken} from "./TestSupport.sol";
import {CapacityReservations as Inventory} from "../src/CapacityReservations.sol";
import {DirectBookingMarket} from "../src/DirectBookingMarket.sol";
import {MarketEscrow} from "../src/MarketEscrow.sol";
import {ReservedTenderMarket, CapacityAdmittedTender} from "../src/tender/ReservedTenderMarket.sol";

contract RealTenderCapacityTest is TestSupport {
    Inventory inventory;
    MockPaymentToken token;
    DirectBookingMarket booking;
    ReservedTenderMarket router;
    CapacityAdmittedTender tender;
    address constant BUYER = address(0xB0B);
    address constant A = address(0xA11CE);
    address constant B = address(0xBEA);
    uint256 poolA;
    uint256 poolB;
    bytes32 constant SALT = keccak256("salt");

    function setUp() public {
        vm.warp(1000);
        inventory = new Inventory();
        token = new MockPaymentToken();
        booking = new DirectBookingMarket(inventory, token);
        router = new ReservedTenderMarket(booking);
        tender = router.tender();
        poolA = pool(A, 100);
        poolB = pool(B, 100);
        token.mint(BUYER, 1000);
        vm.prank(BUYER);
        token.approve(address(router), type(uint256).max);
    }

    function pool(address provider, uint256 price) internal returns (uint256 id) {
        address[] memory adapters = new address[](1);
        adapters[0] = address(booking);
        vm.startPrank(provider);
        id = inventory.createPool(
            Inventory.PoolConfig(keccak256("report"), keccak256("terms"), 1, 2000, 3000, 1000), adapters
        );
        booking.configure(id, price, 4000);
        vm.stopPrank();
    }

    function open() internal returns (bytes32 id) {
        vm.prank(BUYER);
        id = router.open(poolA, 1, 1100, 1200);
    }

    function bid(bytes32 id, address provider, uint256 poolId) internal returns (uint256 reservation) {
        vm.startPrank(provider);
        router.selectPool(id, poolId);
        tender.commitBid(id, keccak256(abi.encode(id, provider, uint256(100), SALT)));
        vm.stopPrank();
        return router.bidReservation(id, provider);
    }

    function award(bytes32 id, address provider) internal {
        vm.warp(1101);
        vm.prank(provider);
        tender.revealBid(id, 100, SALT);
        vm.warp(1201);
        tender.finalize(id);
    }

    function funded() internal returns (bytes32 id, uint256 reservation) {
        id = open();
        reservation = bid(id, A, poolA);
        award(id, A);
        router.settle(id);
    }

    function state(bytes32 id) internal view returns (ReservedTenderMarket.State s) {
        (,,,,,, s) = router.jobs(id);
    }

    function test_ActualAwardFundsOriginalReservationAndPaysForDelivery() public {
        (bytes32 id, uint256 r) = funded();
        eq(uint256(inventory.getReservation(r).status), uint256(Inventory.Status.Confirmed));
        eq(booking.getOrder(r).amount, 100);
        eq(booking.getOrder(r).binding.beneficiary, address(router));
        eq(router.pendingFunds(), 0);
        eq(token.balanceOf(address(booking)), 100);
        eq(token.allowance(address(router), address(booking)), 0);
        vm.expectRevert();
        router.settle(id);
        vm.warp(2000);
        vm.startPrank(A);
        booking.admit(r);
        booking.submit(r, keccak256("completed report"));
        vm.stopPrank();
        vm.prank(BUYER);
        router.accept(id);
        eq(token.balanceOf(A), 100);
        eq(inventory.getPool(poolA).consumed, 1);
        eq(booking.escrowLiability(), 0);
        vm.prank(BUYER);
        vm.expectRevert();
        router.accept(id);
    }

    function test_SecondTenderCannotCommitSameCapacity() public {
        bytes32 first = open();
        bytes32 second = open();
        bid(first, A, poolA);
        vm.startPrank(A);
        router.selectPool(second, poolA);
        bytes32 hash = keccak256(abi.encode(second, A, uint256(100), SALT));
        vm.expectRevert(Inventory.InsufficientCapacity.selector);
        tender.commitBid(second, hash);
        vm.stopPrank();
        eq(router.bidReservation(second, A), 0);
        eq(inventory.getPool(poolA).held, 1);
        eq(router.pendingFunds(), 200);
        eq(token.balanceOf(address(router)), 200);
    }

    function test_CoreRejectionRollsBackPrecommitHoldAndCanRetry() public {
        bytes32 id = open();
        vm.startPrank(A);
        router.selectPool(id, poolA);
        vm.expectRevert();
        tender.commitBid(id, bytes32(0));
        eq(router.bidReservation(id, A), 0);
        eq(inventory.getPool(poolA).held, 0);
        eq(booking.nonces(address(router)), 0);
        tender.commitBid(id, keccak256(abi.encode(id, A, uint256(100), SALT)));
        vm.stopPrank();
        eq(inventory.getPool(poolA).held, 1);
    }

    function test_CannotBypassAdmissionOrReleaseLiveBid() public {
        bytes32 id = open();
        vm.prank(A);
        vm.expectRevert();
        tender.commitBid(id, SALT);
        vm.expectRevert(ReservedTenderMarket.Unauthorized.selector);
        router.admitBid(id, A);
        uint256 r = bid(id, A, poolA);
        vm.prank(A);
        vm.expectRevert();
        inventory.release(r);
        vm.prank(BUYER);
        vm.expectRevert();
        inventory.release(r);
        vm.expectRevert();
        router.releaseBid(id, A);
    }

    function test_LoserReleaseRequiresFinalAwardAndCannotReplay() public {
        bytes32 id = open();
        uint256 winner = bid(id, A, poolA);
        uint256 loser = bid(id, B, poolB);
        vm.warp(1101);
        vm.prank(B);
        tender.revealBid(id, 100, SALT);
        vm.prank(A);
        tender.revealBid(id, 100, SALT);
        vm.warp(1201);
        tender.finalize(id);
        router.releaseBid(id, B);
        eq(uint256(inventory.getReservation(loser).status), uint256(Inventory.Status.Released));
        vm.expectRevert();
        router.releaseBid(id, B);
        vm.expectRevert();
        router.releaseBid(id, A);
        router.settle(id);
        eq(uint256(inventory.getReservation(winner).status), uint256(Inventory.Status.Confirmed));
    }

    function test_VoidReleasesCapacityAndRefundsOnlyOriginalBuyer() public {
        bytes32 id = open();
        uint256 r = bid(id, A, poolA);
        vm.warp(1201);
        tender.finalize(id);
        router.releaseBid(id, A);
        router.refundUnexecuted(id);
        eq(token.balanceOf(BUYER), 1000);
        eq(router.pendingFunds(), 0);
        eq(uint256(inventory.getReservation(r).status), uint256(Inventory.Status.Released));
        vm.expectRevert();
        router.refundUnexecuted(id);
    }

    function test_FailedPaymentRollsBackOrderAndCapacityThenRetrySucceeds() public {
        bytes32 id = open();
        uint256 r = bid(id, A, poolA);
        award(id, A);
        token.setMode(1);
        vm.expectRevert();
        router.settle(id);
        eq(uint256(state(id)), uint256(ReservedTenderMarket.State.Open));
        eq(uint256(inventory.getReservation(r).status), uint256(Inventory.Status.Held));
        eq(router.pendingFunds(), 100);
        eq(booking.escrowLiability(), 0);
        eq(token.balanceOf(address(router)), 100);
        eq(token.allowance(address(router), address(booking)), 0);
        vm.expectRevert();
        booking.getOrder(r);
        token.setMode(0);
        router.settle(id);
        eq(booking.escrowLiability(), 100);
    }

    function test_ProviderAndTermsMustMatchTheCommittedService() public {
        uint256 wrongPrice = pool(A, 99);
        bytes32 id = open();
        vm.prank(B);
        vm.expectRevert();
        router.selectPool(id, poolA);
        vm.prank(A);
        vm.expectRevert();
        router.selectPool(id, wrongPrice);
    }

    function test_LateAwardCannotExecuteAndUnfinalizedTenderCannotStrandPrefund() public {
        bytes32 id = open();
        uint256 r = bid(id, A, poolA);
        vm.warp(1101);
        vm.prank(A);
        tender.revealBid(id, 100, SALT);
        vm.warp(2000);
        inventory.expire(r);
        router.refundUnexecuted(id);
        tender.finalize(id);
        vm.expectRevert();
        router.settle(id);
        eq(token.balanceOf(BUYER), 1000);
        eq(router.pendingFunds(), 0);
        eq(uint256(inventory.getReservation(r).status), uint256(Inventory.Status.Expired));
    }

    function test_BuyerCancellationReturnsActualEscrowAndCapacityOnce() public {
        (bytes32 id, uint256 r) = funded();
        vm.expectRevert();
        router.cancel(id);
        vm.prank(BUYER);
        router.cancel(id);
        eq(token.balanceOf(BUYER), 1000);
        eq(booking.escrowLiability(), 0);
        eq(uint256(inventory.getReservation(r).status), uint256(Inventory.Status.Released));
        vm.prank(BUYER);
        vm.expectRevert();
        router.cancel(id);
    }

    function test_ConsumedWorkTimeoutRefundDoesNotRestoreCapacity() public {
        (bytes32 id, uint256 r) = funded();
        vm.warp(2000);
        vm.prank(A);
        booking.admit(r);
        vm.expectRevert();
        router.refundOrder(id);
        vm.warp(4000);
        router.refundOrder(id);
        eq(token.balanceOf(BUYER), 1000);
        eq(inventory.getPool(poolA).consumed, 1);
        eq(booking.escrowLiability(), 0);
    }

    function test_PaymentCallbackCannotReenterSettlement() public {
        bytes32 id = open();
        bid(id, A, poolA);
        award(id, A);
        token.setHook(address(router), abi.encodeCall(router.settle, (id)));
        router.settle(id);
        no(token.hookSucceeded());
        eq(router.pendingFunds(), 0);
        eq(booking.escrowLiability(), 100);
    }
}
