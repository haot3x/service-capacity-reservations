// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture, Vm, SigningWallet, RevertingAdmissionMarket, OrderHarness} from "./TestSupport.sol";
import {CapacityReservations} from "../src/CapacityReservations.sol";
import {MarketEscrow} from "../src/MarketEscrow.sol";
import {SignedBookingMarket} from "../src/SignedBookingMarket.sol";
import {IReservationOrder} from "../src/interfaces/IReservationOrder.sol";
import {IERC2135} from "../src/interfaces/IERC2135.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ReservationsTest is Fixture {
    function testDemo_TwoMarketsShareTenReportAdmissions() public {
        uint256 first = book(6);
        SignedBookingMarket.HoldRequest memory req = request(5);
        bytes memory sig = signature(signedMarket, req);
        vm.expectRevert(CapacityReservations.InsufficientCapacity.selector);
        signedMarket.holdSigned(req, sig);
        eq(signedMarket.nonces(bob), 0);
        emit log_named_uint("After direct market reserves six: remaining", available());
        req = request(4);
        sig = signature(signedMarket, req);
        uint256 second = signedMarket.holdSigned(req, sig);
        vm.prank(bob);
        signedMarket.confirm(second);
        eq(available(), 0);
        emit log_named_uint("After signed market reserves four: remaining", available());
        vm.warp(START);
        vm.prank(PROVIDER);
        direct.admit(first);
        vm.prank(PROVIDER);
        signedMarket.admit(second);
        eq(registry.getPool(poolId).consumed, 10);
        vm.prank(PROVIDER);
        direct.submit(first, keccak256("six completed reports"));
        vm.prank(ALICE);
        direct.accept(first);
        vm.warp(DEADLINE);
        signedMarket.claimRefund(second);
        eq(token.balanceOf(PROVIDER), 600);
        eq(token.balanceOf(bob), 100_000);
        eq(available(), 0);
        emit log_named_uint(
            "Consumed quota after success and timeout refund", registry.getPool(poolId).consumed
        );
        emit log_named_uint("Provider payment", token.balanceOf(PROVIDER));
        assertAccounting();
    }

    function testFuzz_TwoMarketsCannotOverbook(uint8 firstRaw, uint8 secondRaw) public {
        uint64 first = uint64(firstRaw % 10 + 1);
        uint64 second = uint64(secondRaw % 10 + 1);
        holdDirect(first);
        SignedBookingMarket.HoldRequest memory req = request(second);
        bytes memory sig = signature(signedMarket, req);
        if (first + second > 10) vm.expectRevert(CapacityReservations.InsufficientCapacity.selector);
        signedMarket.holdSigned(req, sig);
        assertAccounting();
    }

    function test_LastUnitHasOnlyOneWinner() public {
        holdDirect(9);
        SignedBookingMarket.HoldRequest memory req = request(1);
        bytes memory sig = signature(signedMarket, req);
        signedMarket.holdSigned(req, sig);
        vm.prank(ALICE);
        vm.expectRevert(CapacityReservations.InsufficientCapacity.selector);
        direct.hold(poolId, 1, 1_500);
        eq(direct.nonces(ALICE), 1);
        eq(available(), 0);
        assertAccounting();
    }

    function test_HoldExpiryRequiresCleanupAndCannotConfirmAtDeadline() public {
        uint256 id = holdDirect(10);
        vm.warp(1_500);
        vm.prank(ALICE);
        vm.expectRevert(CapacityReservations.DeadlinePassed.selector);
        direct.confirm(id);
        eq(token.balanceOf(ALICE), 100_000);
        eq(direct.escrowLiability(), 0);
        vm.expectRevert(MarketEscrow.UnknownOrder.selector);
        direct.getOrder(id);
        eq(available(), 0);
        registry.expire(id);
        eq(available(), 10);
        vm.expectRevert(CapacityReservations.InvalidState.selector);
        registry.expire(id);
        assertAccounting();
    }

    function test_CancelAtomicallyReturnsInventoryAndFundsExactlyOnce() public {
        uint256 id = book(6);
        eq(token.balanceOf(ALICE), 99_400);
        vm.prank(ALICE);
        direct.cancel(id);
        status(id, CapacityReservations.Status.Released);
        eq(token.balanceOf(ALICE), 100_000);
        eq(available(), 10);
        vm.expectRevert(MarketEscrow.InvalidState.selector);
        direct.claimRefund(id);
        vm.prank(PROVIDER);
        vm.expectRevert(MarketEscrow.InvalidState.selector);
        direct.admit(id);
        assertAccounting();
    }

    function test_DirectLedgerReleaseStillAllowsRefundToBuyer() public {
        uint256 id = book(3);
        vm.prank(ALICE);
        registry.release(id);
        eq(direct.escrowLiability(), 300);
        vm.prank(address(0xBAD));
        direct.claimRefund(id);
        eq(token.balanceOf(ALICE), 100_000);
        eq(token.balanceOf(address(0xBAD)), 0);
        assertAccounting();
    }

    function test_ThirdPartyExpiryDoesNotStrandFunds() public {
        uint256 id = book(10);
        vm.warp(END - 1);
        vm.expectRevert(CapacityReservations.TooEarly.selector);
        registry.expire(id);
        vm.expectRevert(MarketEscrow.RefundUnavailable.selector);
        direct.claimRefund(id);
        vm.warp(END);
        registry.expire(id);
        direct.claimRefund(id);
        eq(token.balanceOf(ALICE), 100_000);
        (uint256 remaining, bool open) = registry.availability(poolId);
        eq(remaining, 10);
        no(open);
        vm.prank(ALICE);
        vm.expectRevert(CapacityReservations.InvalidHold.selector);
        direct.hold(poolId, 1, END + 100);
        assertAccounting();
    }

    function test_RefundCanAlsoExpireUnusedConfirmationAtomically() public {
        uint256 id = book(2);
        vm.warp(END);
        direct.claimRefund(id);
        status(id, CapacityReservations.Status.Expired);
        eq(token.balanceOf(ALICE), 100_000);
        assertAccounting();
    }

    function test_ExactAdmissionWindowAndCancellationBoundaries() public {
        uint256 id = book(2);
        vm.warp(START - 1);
        no(registry.isConsumableBy(ALICE, id, 2));
        vm.prank(PROVIDER);
        vm.expectRevert(CapacityReservations.NotConsumable.selector);
        direct.admit(id);
        vm.warp(START);
        yes(registry.isConsumableBy(ALICE, id, 2));
        vm.prank(ALICE);
        vm.expectRevert(CapacityReservations.DeadlinePassed.selector);
        direct.cancel(id);
        vm.prank(PROVIDER);
        direct.admit(id);
        vm.prank(PROVIDER);
        vm.expectRevert(MarketEscrow.InvalidState.selector);
        direct.admit(id);
        vm.expectRevert(CapacityReservations.InvalidState.selector);
        registry.expire(id);
        eq(available(), 8);
        assertAccounting();
    }

    function test_AdmissionAtEndIsForbidden() public {
        uint256 id = book(1);
        vm.warp(END);
        no(registry.isConsumableBy(ALICE, id, 1));
        vm.prank(PROVIDER);
        vm.expectRevert(CapacityReservations.NotConsumable.selector);
        direct.admit(id);
        direct.claimRefund(id);
        assertAccounting();
    }

    function test_WorkFailureRefundNeverReissuesConsumedQuota() public {
        uint256 id = book(4);
        vm.warp(START);
        vm.prank(PROVIDER);
        direct.admit(id);
        vm.warp(DEADLINE - 1);
        vm.expectRevert(MarketEscrow.RefundUnavailable.selector);
        direct.claimRefund(id);
        vm.warp(DEADLINE);
        direct.claimRefund(id);
        status(id, CapacityReservations.Status.Consumed);
        eq(registry.getPool(poolId).consumed, 4);
        eq(registry.totalSupply(), 6);
        eq(available(), 6);
        eq(token.balanceOf(ALICE), 100_000);
        assertAccounting();
    }

    function test_RejectRefundsButDoesNotRestoreQuota() public {
        uint256 id = book(1);
        vm.warp(START);
        vm.startPrank(PROVIDER);
        direct.admit(id);
        direct.submit(id, keccak256("result"));
        vm.stopPrank();
        vm.prank(ALICE);
        direct.reject(id);
        vm.prank(ALICE);
        vm.expectRevert(MarketEscrow.InvalidState.selector);
        direct.accept(id);
        eq(token.balanceOf(PROVIDER), 0);
        eq(token.balanceOf(ALICE), 100_000);
        eq(available(), 9);
        assertAccounting();
    }

    function test_AcceptAtSettlementDeadlineFailsThenRefunds() public {
        uint256 id = book(1);
        vm.warp(START);
        vm.startPrank(PROVIDER);
        direct.admit(id);
        direct.submit(id, keccak256("result"));
        vm.stopPrank();
        vm.warp(DEADLINE);
        vm.prank(ALICE);
        vm.expectRevert(MarketEscrow.DeadlinePassed.selector);
        direct.accept(id);
        direct.claimRefund(id);
        assertAccounting();
    }

    function test_FailedFundsOrNonExactTransferRollBackEverything() public {
        uint256 id = holdDirect(2);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            token.setMode(mode);
            vm.prank(ALICE);
            vm.expectRevert();
            direct.confirm(id);
            status(id, CapacityReservations.Status.Held);
            eq(token.balanceOf(ALICE), 100_000);
            eq(direct.escrowLiability(), 0);
        }
        token.setMode(0);
        vm.prank(ALICE);
        direct.confirm(id);
        assertAccounting();
    }

    function test_NoAllowanceCannotConfirm() public {
        uint256 id = holdDirect(1);
        vm.startPrank(ALICE);
        token.approve(address(direct), 0);
        vm.expectRevert();
        direct.confirm(id);
        vm.stopPrank();
        status(id, CapacityReservations.Status.Held);
        eq(direct.escrowLiability(), 0);
        assertAccounting();
    }

    function test_FailedRefundRollsBackInventoryRelease() public {
        uint256 id = book(2);
        token.setMode(2);
        vm.prank(ALICE);
        vm.expectRevert(MarketEscrow.UnexpectedTokenMovement.selector);
        direct.cancel(id);
        status(id, CapacityReservations.Status.Confirmed);
        eq(available(), 8);
        eq(direct.escrowLiability(), 200);
        token.setMode(0);
        vm.prank(ALICE);
        direct.cancel(id);
        assertAccounting();
    }

    function test_PaymentCallbackCannotReenterConfirmationOrRefund() public {
        uint256 id = holdDirect(2);
        token.setHook(address(direct), abi.encodeCall(direct.confirm, (id)));
        vm.prank(ALICE);
        direct.confirm(id);
        no(token.hookSucceeded());
        yes(token.hookError() == ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        token.setHook(address(direct), abi.encodeCall(direct.claimRefund, (id)));
        vm.prank(ALICE);
        direct.cancel(id);
        no(token.hookSucceeded());
        yes(token.hookError() == ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        eq(token.balanceOf(ALICE), 100_000);
        assertAccounting();
    }

    function test_AuthorityAndBoundMarketAreEnforced() public {
        vm.prank(ALICE);
        vm.expectRevert(CapacityReservations.Unauthorized.selector);
        registry.hold(poolId, ALICE, 1, 1_500, bytes32(uint256(1)));
        uint256 id = holdDirect(1);
        vm.prank(bob);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        direct.confirm(id);
        vm.prank(ALICE);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        signedMarket.confirm(id);
        vm.prank(ALICE);
        direct.confirm(id);
        vm.prank(PROVIDER);
        vm.expectRevert(CapacityReservations.Unauthorized.selector);
        registry.release(id);
        vm.prank(bob);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        direct.cancel(id);
        vm.warp(START);
        vm.prank(ALICE);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        direct.admit(id);
        vm.prank(ALICE);
        vm.expectRevert(CapacityReservations.Unauthorized.selector);
        registry.consume(ALICE, id, 1, abi.encode(address(direct), bytes32(id)));
        assertAccounting();
    }

    function test_ReceiptCustodyCannotBeDrainedByProviderApproval() public {
        uint256 id = book(3);
        vm.prank(PROVIDER);
        registry.setApprovalForAll(ALICE, true);
        vm.prank(ALICE);
        vm.expectRevert();
        registry.safeTransferFrom(address(registry), ALICE, id, 3, "");
        vm.prank(PROVIDER);
        vm.expectRevert();
        registry.safeTransferFrom(address(registry), PROVIDER, poolId, 7, "");
        eq(registry.balanceOf(address(registry), id), 3);
        eq(registry.balanceOf(ALICE, id), 0);
        assertAccounting();
    }

    function test_2135InterfacesAndRealConsumptionBurnEvents() public {
        yes(type(IERC2135).interfaceId == 0xdd691946);
        yes(registry.supportsInterface(0x01ffc9a7));
        yes(registry.supportsInterface(0xd9b67a26));
        yes(registry.supportsInterface(0xdd691946));
        no(registry.supportsInterface(0xffffffff));
        uint256 id = book(2);
        vm.warp(START);
        no(registry.isConsumableBy(ALICE, poolId, 2));
        no(registry.isConsumableBy(bob, id, 2));
        no(registry.isConsumableBy(ALICE, id, 1));
        no(registry.isConsumableBy(ALICE, 999, 2));
        vm.recordLogs();
        vm.prank(PROVIDER);
        direct.admit(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool burn;
        bool consumed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(registry)) continue;
            if (logs[i].topics[0] == keccak256("TransferSingle(address,address,address,uint256,uint256)")) {
                eq(address(uint160(uint256(logs[i].topics[2]))), address(registry));
                eq(uint256(logs[i].topics[3]), 0);
                (uint256 assetId, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
                eq(assetId, id);
                eq(amount, 2);
                burn = true;
            }
            if (logs[i].topics[0] == keccak256("OnConsumption(address,uint256,uint256,bytes)")) {
                eq(address(uint160(uint256(logs[i].topics[1]))), ALICE);
                eq(uint256(logs[i].topics[2]), id);
                (uint256 amount, bytes memory data) = abi.decode(logs[i].data, (uint256, bytes));
                eq(amount, 2);
                yes(keccak256(data) == keccak256(abi.encode(address(direct), bytes32(id))));
                consumed = true;
            }
        }
        yes(burn);
        yes(consumed);
        eq(registry.balanceOf(address(registry), id), 0);
        no(registry.isConsumableBy(ALICE, id, 2));
        assertAccounting();
    }

    function test_FailedOrderAdmissionRollsBackConsumption() public {
        RevertingAdmissionMarket broken = new RevertingAdmissionMarket(registry, token);
        address[] memory adapters = new address[](1);
        adapters[0] = address(broken);
        vm.prank(PROVIDER);
        uint256 pool = registry.createPool(config(), adapters);
        vm.prank(PROVIDER);
        broken.configure(pool, PRICE, DEADLINE);
        vm.startPrank(ALICE);
        token.approve(address(broken), type(uint256).max);
        uint256 id = broken.hold(pool, 2, 1_500);
        broken.confirm(id);
        vm.stopPrank();
        vm.warp(START);
        vm.prank(PROVIDER);
        vm.expectRevert(RevertingAdmissionMarket.AdmissionUpdateFailed.selector);
        broken.admit(id);
        status(id, CapacityReservations.Status.Confirmed);
        eq(registry.getPool(pool).consumed, 0);
        eq(registry.getPool(pool).confirmed, 2);
        eq(registry.balanceOf(address(registry), id), 2);
        eq(uint256(broken.getOrder(id).status), uint256(MarketEscrow.OrderStatus.Funded));
    }

    function test_EveryImmutableBindingFieldIsRecheckedBeforeConsumption() public {
        uint256 id = book(2);
        IReservationOrder.Binding memory good = direct.reservationOrder(id);
        vm.warp(START);
        for (uint256 i; i < 10; ++i) {
            IReservationOrder.Binding memory bad = changed(good, i);
            vm.mockCall(address(direct), abi.encodeCall(direct.reservationOrder, (id)), abi.encode(bad));
            no(registry.isConsumableBy(ALICE, id, 2));
            vm.prank(PROVIDER);
            vm.expectRevert(CapacityReservations.NotConsumable.selector);
            direct.admit(id);
            status(id, CapacityReservations.Status.Confirmed);
            vm.clearMockedCalls();
        }
        vm.prank(PROVIDER);
        direct.admit(id);
        assertAccounting();
    }

    function test_IncompatibleBindingRollsBackFunding() public {
        uint256 id = holdDirect(2);
        IReservationOrder.Binding memory good = IReservationOrder.Binding(
            PROVIDER,
            ALICE,
            config().serviceHash,
            config().termsHash,
            poolId,
            2,
            START,
            END,
            bytes32(id),
            true
        );
        for (uint256 i; i < 10; ++i) {
            vm.mockCall(
                address(direct), abi.encodeCall(direct.reservationOrder, (id)), abi.encode(changed(good, i))
            );
            vm.prank(ALICE);
            vm.expectRevert(CapacityReservations.InvalidOrder.selector);
            direct.confirm(id);
            status(id, CapacityReservations.Status.Held);
            eq(token.balanceOf(ALICE), 100_000);
            eq(direct.escrowLiability(), 0);
            vm.clearMockedCalls();
        }
        assertAccounting();
    }

    function changed(IReservationOrder.Binding memory good, uint256 field)
        internal
        pure
        returns (IReservationOrder.Binding memory bad)
    {
        bad = abi.decode(abi.encode(good), (IReservationOrder.Binding));
        if (field == 0) bad.provider = address(1);
        if (field == 1) bad.beneficiary = address(1);
        if (field == 2) bad.serviceHash = bytes32(uint256(1));
        if (field == 3) bad.termsHash = bytes32(uint256(1));
        if (field == 4) bad.poolId++;
        if (field == 5) bad.units++;
        if (field == 6) bad.windowStart++;
        if (field == 7) bad.windowEnd++;
        if (field == 8) bad.orderId = bytes32(uint256(999));
        if (field == 9) bad.funded = false;
    }

    function test_OrderAndRequestReplayRejectedAndConsumeDataBound() public {
        OrderHarness harness = new OrderHarness(registry);
        address[] memory adapters = new address[](1);
        adapters[0] = address(harness);
        vm.prank(PROVIDER);
        uint256 pool = registry.createPool(config(), adapters);
        uint256 id = harness.hold(pool, ALICE, 1, 1_500, keccak256("first"));
        vm.expectRevert(CapacityReservations.RequestAlreadyUsed.selector);
        harness.hold(pool, ALICE, 1, 1_500, keccak256("first"));
        bytes32 order = keccak256("same order");
        IReservationOrder.Binding memory binding = IReservationOrder.Binding(
            PROVIDER, ALICE, config().serviceHash, config().termsHash, pool, 1, START, END, order, true
        );
        harness.setBinding(id, binding);
        harness.confirm(id, order);
        uint256 second = harness.hold(pool, ALICE, 1, 1_500, keccak256("second"));
        harness.setBinding(second, binding);
        vm.expectRevert(CapacityReservations.OrderAlreadyBound.selector);
        harness.confirm(second, order);
        vm.warp(START);
        vm.expectRevert(CapacityReservations.InvalidOrder.selector);
        harness.consume(ALICE, id, 1, abi.encode(address(direct), order));
        vm.expectRevert(CapacityReservations.InvalidOrder.selector);
        harness.consume(ALICE, id, 1, "");
        vm.expectRevert(CapacityReservations.NotConsumable.selector);
        harness.consume(ALICE, id, 0, abi.encode(address(harness), order));
        yes(harness.consume(ALICE, id, 1, abi.encode(address(harness), order)));
    }

    function test_InvalidPoolParametersAndImmutableOffer() public {
        address[] memory adapters = new address[](1);
        adapters[0] = ALICE;
        CapacityReservations.PoolConfig memory c = config();
        vm.expectRevert(CapacityReservations.InvalidPool.selector);
        registry.createPool(c, adapters);
        adapters[0] = address(direct);
        c.capacity = 0;
        vm.expectRevert(CapacityReservations.InvalidPool.selector);
        registry.createPool(c, adapters);
        c = config();
        c.windowEnd = c.windowStart;
        vm.expectRevert(CapacityReservations.InvalidPool.selector);
        registry.createPool(c, adapters);
        c = config();
        c.windowStart = 1_000;
        vm.expectRevert(CapacityReservations.InvalidPool.selector);
        registry.createPool(c, adapters);
        adapters = new address[](2);
        adapters[0] = address(direct);
        adapters[1] = address(direct);
        c = config();
        vm.expectRevert(CapacityReservations.InvalidPool.selector);
        registry.createPool(c, adapters);
        vm.prank(ALICE);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        direct.configure(poolId, 1, DEADLINE);
        vm.prank(PROVIDER);
        vm.expectRevert(MarketEscrow.InvalidOffer.selector);
        direct.configure(poolId, 1, DEADLINE);
        eq(registry.getPool(poolId).provider, PROVIDER);
    }

    function test_InvalidHoldsAndUnknownRecords() public {
        vm.startPrank(ALICE);
        vm.expectRevert(CapacityReservations.InvalidHold.selector);
        direct.hold(poolId, 0, 1_500);
        vm.expectRevert(CapacityReservations.InvalidHold.selector);
        direct.hold(poolId, 1, 1_000);
        vm.expectRevert(CapacityReservations.InvalidHold.selector);
        direct.hold(poolId, 1, 2_001);
        vm.expectRevert(CapacityReservations.InvalidHold.selector);
        direct.hold(poolId, 1, START + 1);
        vm.stopPrank();
        vm.expectRevert(CapacityReservations.UnknownPool.selector);
        registry.availability(999);
        vm.expectRevert(CapacityReservations.UnknownReservation.selector);
        registry.getReservation(999);
        vm.expectRevert(CapacityReservations.ForeignToken.selector);
        registry.onERC1155Received(ALICE, ALICE, 1, 1, "");
        assertAccounting();
    }
}

contract SignedHoldsTest is Fixture {
    function test_RelayerCannotAlterTermsOrReplaySignature() public {
        SignedBookingMarket.HoldRequest memory req = request(2);
        bytes memory sig = signature(signedMarket, req);
        req.units = 3;
        vm.expectRevert(SignedBookingMarket.InvalidSignature.selector);
        signedMarket.holdSigned(req, sig);
        req.units = 2;
        vm.prank(address(0xCAFE));
        uint256 id = signedMarket.holdSigned(req, sig);
        eq(registry.getReservation(id).beneficiary, bob);
        vm.expectRevert(SignedBookingMarket.InvalidSignature.selector);
        signedMarket.holdSigned(req, sig);
        assertAccounting();
    }

    function test_SignaturesAreBoundToChainAndMarket() public {
        SignedBookingMarket.HoldRequest memory req = request(1);
        bytes memory sig = signature(signedMarket, req);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(SignedBookingMarket.InvalidSignature.selector);
        signedMarket.holdSigned(req, sig);
        SignedBookingMarket other = new SignedBookingMarket(registry, token);
        sig = signature(signedMarket, req);
        vm.expectRevert(SignedBookingMarket.InvalidSignature.selector);
        other.holdSigned(req, sig);
    }

    function test_SignatureExpiryIsExclusive() public {
        SignedBookingMarket.HoldRequest memory req = request(1);
        bytes memory sig = signature(signedMarket, req);
        vm.warp(req.validUntil);
        vm.expectRevert(SignedBookingMarket.InvalidSignature.selector);
        signedMarket.holdSigned(req, sig);
        eq(signedMarket.nonces(bob), 0);
    }

    function test_ERC1271ContractBuyerCanAuthorizeHold() public {
        SigningWallet wallet = new SigningWallet(bob);
        SignedBookingMarket.HoldRequest memory req = request(2);
        req.buyer = address(wallet);
        bytes memory sig = signature(signedMarket, req);
        uint256 id = signedMarket.holdSigned(req, sig);
        eq(registry.getReservation(id).beneficiary, address(wallet));
        eq(signedMarket.nonces(address(wallet)), 1);
        assertAccounting();
    }
}
