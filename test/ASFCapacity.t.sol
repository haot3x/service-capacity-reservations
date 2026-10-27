// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestSupport, MockPaymentToken} from "./TestSupport.sol";
import {CapacityReservations} from "../src/CapacityReservations.sol";
import {DirectBookingMarket} from "../src/DirectBookingMarket.sol";
import {MarketEscrow} from "../src/MarketEscrow.sol";
import {ASFCapacityMarket} from "../src/asf/ASFCapacityMarket.sol";
import {CapacitySafetyPolicy as Policy} from "../src/asf/CapacitySafetyPolicy.sol";
import {ASFTypes as T} from "../vendor/asf/ASFTypes.sol";
import {ASFKeys} from "../vendor/asf/libraries/ASFKeys.sol";
import {ASFBindingRegistry} from "../vendor/asf/ASFBindingRegistry.sol";
import {ASFSpecificationRegistry} from "../vendor/asf/ASFSpecificationRegistry.sol";
import {IASFSpecificationRegistry} from "../vendor/asf/interfaces/IASFSpecificationRegistry.sol";

contract ASFCapacityTest is TestSupport {
    CapacityReservations private capacity;
    MockPaymentToken private token;
    ASFCapacityMarket private market;
    ASFSpecificationRegistry private specs;
    ASFBindingRegistry private safety;
    address private constant PROVIDER = address(0xA11CE);
    address private constant BUYER = address(0xB0B);
    address private guardian;
    uint64 private constant START = 10_000;
    uint64 private constant END = 20_000;
    uint64 private constant DEADLINE = 30_000;
    bytes32 private specId;
    uint256 private pool;
    bytes32 private root;
    bytes32 private leaf;

    function setUp() public {
        vm.warp(1_000);
        capacity = new CapacityReservations();
        token = new MockPaymentToken();
        safety = new ASFBindingRegistry();
        specs = new ASFSpecificationRegistry();
        bytes32[] memory profiles = new bytes32[](1);
        profiles[0] = Policy.PROFILE;
        specId = specs.registerSpecification(
            keccak256("capacity"), Policy.SPECIFICATION, "local:specification", profiles
        );
        guardian = address(0xCA2D);
        _install();
        token.mint(BUYER, 100_000);
    }

    function _install() private {
        market = new ASFCapacityMarket(capacity, token, safety, specs, specId, guardian);
        address[] memory adapters = new address[](1);
        adapters[0] = address(market);
        pool = _pool(adapters);
        T.BindingInput memory input = _input(pool, bytes32(0), keccak256("root"));
        vm.prank(PROVIDER);
        root = safety.adopt(input);
        input.parentBindingId = root;
        input.salt = keccak256("leaf");
        vm.prank(PROVIDER);
        leaf = safety.adopt(input);
        vm.prank(PROVIDER);
        market.configureSafety(pool, leaf);
        vm.prank(BUYER);
        token.approve(address(market), type(uint256).max);
    }

    function _pool(address[] memory adapters) private returns (uint256 id) {
        CapacityReservations.PoolConfig memory config = CapacityReservations.PoolConfig(
            keccak256("bounded report"), Policy.SPECIFICATION, 10, START, END, 1_000
        );
        vm.prank(PROVIDER);
        id = capacity.createPool(config, adapters);
        vm.prank(PROVIDER);
        market.configure(id, 100, DEADLINE);
    }

    function _input(uint256 poolId, bytes32 parent, bytes32 salt)
        private
        view
        returns (T.BindingInput memory i)
    {
        i.subjectKey = ASFKeys.accountSubjectKey(PROVIDER);
        i.scopeKey = market.scopeKey(poolId);
        i.specRegistry = address(specs);
        i.specId = specId;
        i.version = 1;
        i.contentHash = Policy.SPECIFICATION;
        i.paramsHash = Policy.PARAMETERS;
        i.authorityRef = market.authorityRef(poolId);
        i.enforcement = T.ENFORCED_CONTRACT;
        i.validUntil = 40_000;
        i.parentBindingId = parent;
        i.salt = salt;
        i.interveners = new T.Intervener[](1);
        i.interveners[0] = T.Intervener(guardian, T.RIGHT_ALL);
    }

    function _hold() private returns (uint256 id) {
        vm.prank(BUYER);
        id = market.hold(pool, 1, uint64(block.timestamp + 500));
    }

    function _book() private returns (uint256 id) {
        id = _hold();
        vm.prank(BUYER);
        market.confirm(id);
    }

    function _admit(uint256 id) private {
        vm.prank(PROVIDER);
        market.admit(id);
    }

    function _pause(bytes32 id, uint8 flags) private {
        vm.prank(guardian);
        safety.suspend(id, flags, bytes32(0), keccak256("incident"));
    }

    function _resume(bytes32 id) private {
        vm.prank(guardian);
        safety.resume(id, keccak256("resolved"));
    }

    function _sums() private view {
        CapacityReservations.Pool memory p = capacity.getPool(pool);
        eq(capacity.balanceOf(address(capacity), pool) + p.held + p.confirmed + p.consumed, 10);
        eq(token.balanceOf(address(market)), market.escrowLiability());
    }

    function _status(uint256 id, CapacityReservations.Status expected) private view {
        eq(uint256(capacity.getReservation(id).status), uint256(expected));
    }

    function test_ASFActiveLifecycleUsesActualRegistriesAndPinnedDocuments() public {
        yes(
            Policy.SPECIFICATION == keccak256(bytes(vm.readFile("examples/asf/specification.canonical.json")))
        );
        yes(Policy.PARAMETERS == keccak256(bytes(vm.readFile("examples/asf/parameters.canonical.json"))));
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        vm.prank(PROVIDER);
        market.submit(id, keccak256("report"));
        vm.prank(BUYER);
        market.accept(id);
        eq(token.balanceOf(PROVIDER), 100);
        eq(capacity.getPool(pool).consumed, 1);
        _sums();
    }

    function test_ASFUnconfiguredPoolCannotHoldAndOnlyProviderCanConfigure() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(market);
        uint256 other = _pool(adapters);
        vm.prank(BUYER);
        vm.expectRevert(ASFCapacityMarket.SafetyNotConfigured.selector);
        market.hold(other, 1, 1_500);
        vm.prank(BUYER);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        market.configureSafety(other, leaf);
        vm.prank(PROVIDER);
        vm.expectRevert(ASFCapacityMarket.SafetyAuthorityMismatch.selector);
        market.configureSafety(other, leaf);
    }

    function test_ASFMixedAdaptersCannotClaimPoolWideEnforcement() public {
        DirectBookingMarket unguarded = new DirectBookingMarket(capacity, token);
        address[] memory adapters = new address[](2);
        adapters[0] = address(market);
        adapters[1] = address(unguarded);
        uint256 other = _pool(adapters);
        vm.prank(PROVIDER);
        vm.expectRevert(ASFCapacityMarket.InvalidSafetyConfiguration.selector);
        market.configureSafety(other, leaf);
        eq(capacity.adapterCount(other), 2);
    }

    function test_ASFParentPauseBlocksHeldConfirmationWithoutTakingPayment() public {
        uint256 id = _hold();
        _pause(root, T.RESTRICT_NO_NEW_RISK | T.RESTRICT_DERISK_ONLY);
        (T.Verdict v, T.Reason r, uint8 flags) = market.safetyState(pool);
        eq(uint256(v), uint256(T.Verdict.NotSatisfied));
        eq(uint256(r), uint256(T.Reason.ParentNotSatisfied));
        eq(flags, 9);
        eq(safety.bindingOf(leaf).restrictions, 0);
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.confirm(id);
        _status(id, CapacityReservations.Status.Held);
        eq(token.balanceOf(BUYER), 100_000);
        vm.prank(BUYER);
        capacity.release(id);
        _sums();
    }

    function testFuzz_ASFAllSuspensionSetsHaveExplicitAdmissionAndContinuationPolicy(uint8 raw) public {
        uint8 flags = uint8(uint256(raw) % 31 + 1);
        uint256 held = _hold();
        uint256 funded = _book();
        _pause(root, flags);
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.hold(pool, 1, 1_500);
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.confirm(held);
        vm.warp(START);
        vm.prank(PROVIDER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.admit(funded);
        _resume(root);
        _admit(funded);
        _pause(root, flags);
        bool allowed = flags == 4 || flags == 5;
        vm.prank(PROVIDER);
        if (!allowed) vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.submit(funded, keccak256("report"));
        eq(
            uint256(market.getOrder(funded).status),
            uint256(allowed ? MarketEscrow.OrderStatus.Submitted : MarketEscrow.OrderStatus.Admitted)
        );
        eq(capacity.getPool(pool).consumed, 1);
        _sums();
    }

    function test_ASFFullStopDominatesEssentialChildAndParentUnion() public {
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        _pause(root, T.RESTRICT_NO_NEW_RISK | T.RESTRICT_ESSENTIAL_ONLY);
        _pause(leaf, T.RESTRICT_FULL_STOP);
        (,, uint8 flags) = market.safetyState(pool);
        eq(flags, 21);
        vm.prank(PROVIDER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.submit(id, keccak256("report"));
        _sums();
    }

    function test_ASFEssentialOnlyDoesNotAuthorizeUnadmittedWork() public {
        uint256 id = _book();
        _pause(root, T.RESTRICT_ESSENTIAL_ONLY);
        vm.prank(PROVIDER);
        vm.expectRevert(MarketEscrow.InvalidState.selector);
        market.submit(id, keccak256("report"));
    }

    function test_ASFUninterpretedResponseDocumentClosesContinuation() public {
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        vm.prank(guardian);
        safety.suspend(root, T.RESTRICT_ESSENTIAL_ONLY, keccak256("unread response"), bytes32(0));
        vm.prank(PROVIDER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.submit(id, keccak256("report"));
        vm.warp(DEADLINE);
        market.claimRefund(id);
        eq(token.balanceOf(BUYER), 100_000);
        _sums();
    }

    function test_ASFTerminatedAncestorCannotBeTreatedAsContinuingSuspension() public {
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        _pause(leaf, T.RESTRICT_ESSENTIAL_ONLY);
        vm.prank(PROVIDER);
        safety.terminate(root, bytes32(0));
        (,, uint8 flags) = market.safetyState(pool);
        eq(flags, 0);
        vm.prank(PROVIDER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.submit(id, keccak256("report"));
        vm.warp(DEADLINE);
        market.claimRefund(id);
        eq(capacity.getPool(pool).consumed, 1);
        _sums();
    }

    function test_ASFExpiryAtExactBoundaryClosesContinuationButNotRecovery() public {
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        _pause(root, T.RESTRICT_ESSENTIAL_ONLY);
        vm.warp(40_000);
        (T.Verdict v,, uint8 flags) = market.safetyState(pool);
        eq(uint256(v), uint256(T.Verdict.NotSatisfied));
        eq(flags, 0);
        market.claimRefund(id);
        eq(token.balanceOf(BUYER), 100_000);
        _sums();
    }

    function test_ASFBindingExpiresBeforeOrderDeadlineAndBlocksResultSubmission() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(market);
        pool = _pool(adapters);
        T.BindingInput memory i = _input(pool, bytes32(0), keccak256("short validity"));
        i.validUntil = START + 1;
        vm.prank(PROVIDER);
        leaf = safety.adopt(i);
        vm.prank(PROVIDER);
        market.configureSafety(pool, leaf);
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        vm.warp(START + 1);
        vm.prank(PROVIDER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.submit(id, keccak256("report"));
        _status(id, CapacityReservations.Status.Consumed);
        vm.warp(DEADLINE);
        market.claimRefund(id);
        _sums();
    }

    function test_ASFMalformedCheckResponseIsUnknown() public {
        uint256 id = _book();
        T.Reason[] memory reasons = new T.Reason[](0);
        uint8[] memory flags = new uint8[](0);
        vm.mockCall(
            address(safety),
            abi.encodeWithSelector(safety.check.selector),
            abi.encode(T.Verdict.Satisfied, reasons, flags)
        );
        (T.Verdict v,,) = market.safetyState(pool);
        eq(uint256(v), uint256(T.Verdict.Unknown));
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.hold(pool, 1, 1_500);
        vm.prank(BUYER);
        market.cancel(id);
        _sums();
    }

    function test_ASFUnknownDependencyBlocksRiskAndPreservesRefundAuthority() public {
        uint256 id = _book();
        vm.mockCall(
            address(specs),
            abi.encodeWithSignature("supportsInterface(bytes4)", type(IASFSpecificationRegistry).interfaceId),
            abi.encode(false)
        );
        (T.Verdict v,,) = market.safetyState(pool);
        eq(uint256(v), uint256(T.Verdict.Unknown));
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.hold(pool, 1, 1_500);
        vm.prank(BUYER);
        market.cancel(id);
        eq(token.balanceOf(BUYER), 100_000);
        _sums();
    }

    function test_ASFRevertingCheckNeverAuthorizesAndDoesNotStrandExpiredEscrow() public {
        uint256 id = _book();
        vm.mockCallRevert(
            address(safety),
            abi.encodeWithSelector(safety.check.selector),
            abi.encodeWithSignature("Error(string)", "unavailable")
        );
        (T.Verdict v,,) = market.safetyState(pool);
        eq(uint256(v), uint256(T.Verdict.Unknown));
        vm.warp(START);
        vm.prank(PROVIDER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.admit(id);
        vm.warp(END);
        market.claimRefund(id);
        _status(id, CapacityReservations.Status.Expired);
        _sums();
    }

    function test_ASFAdopterCannotResumeGuardianPauseOrReplacePinnedBinding() public {
        _pause(root, T.RESTRICT_NO_NEW_RISK);
        vm.prank(PROVIDER);
        vm.expectRevert();
        safety.resume(root, bytes32(0));
        T.BindingInput memory i = _input(pool, bytes32(0), keccak256("replacement"));
        vm.prank(PROVIDER);
        bytes32 replacement = safety.adopt(i);
        vm.prank(PROVIDER);
        vm.expectRevert(ASFCapacityMarket.SafetyAlreadyConfigured.selector);
        market.configureSafety(pool, replacement);
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.hold(pool, 1, 1_500);
        _resume(root);
        _hold();
        _sums();
    }

    function test_ASFAncestorWithExtraResumeKeyIsRejectedEvenIfLeafLooksValid() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(market);
        uint256 other = _pool(adapters);
        T.BindingInput memory i = _input(other, bytes32(0), keccak256("puppet parent"));
        i.interveners = new T.Intervener[](2);
        i.interveners[0] = T.Intervener(guardian, T.RIGHT_ALL);
        i.interveners[1] = T.Intervener(address(0xBAD), T.RIGHT_RESUME);
        vm.prank(PROVIDER);
        bytes32 parent = safety.adopt(i);
        i = _input(other, parent, keccak256("apparently valid child"));
        vm.prank(PROVIDER);
        bytes32 child = safety.adopt(i);
        // The clause is checked against the leaf. Our narrower consumer also constrains its ancestors.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = child;
        (T.Verdict v,,) = safety.check(market.requirement(other), ids);
        eq(uint256(v), uint256(T.Verdict.Satisfied));
        vm.prank(PROVIDER);
        vm.expectRevert(ASFCapacityMarket.SafetyAuthorityMismatch.selector);
        market.configureSafety(other, child);
    }

    function test_ASFAuthorityReferenceAndParentParametersAreChecked() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(market);
        uint256 other = _pool(adapters);
        T.BindingInput memory i = _input(other, bytes32(0), keccak256("false authority"));
        i.authorityRef = keccak256("self assertion");
        vm.prank(PROVIDER);
        bytes32 bad = safety.adopt(i);
        vm.prank(PROVIDER);
        vm.expectRevert(ASFCapacityMarket.SafetyAuthorityMismatch.selector);
        market.configureSafety(other, bad);
        i = _input(other, bytes32(0), keccak256("different parameters"));
        i.paramsHash = keccak256("wider policy");
        vm.prank(PROVIDER);
        bytes32 parent = safety.adopt(i);
        i = _input(other, parent, keccak256("child"));
        vm.prank(PROVIDER);
        bad = safety.adopt(i);
        vm.prank(PROVIDER);
        vm.expectRevert(ASFCapacityMarket.SafetyAuthorityMismatch.selector);
        market.configureSafety(other, bad);
    }

    function test_ASFPublishedNewVersionCannotChangePinnedPoolPolicy() public {
        bytes32[] memory profiles = new bytes32[](1);
        profiles[0] = Policy.PROFILE;
        specs.publishVersion(specId, keccak256("different v2"), "local:v2", profiles);
        _book();
        eq(specs.latestVersion(specId), 2);
        _sums();
    }

    function test_ASFWrongDocumentOrUnsupportedRequiredProfileCannotDeploy() public {
        bytes32[] memory profiles = new bytes32[](1);
        profiles[0] = keccak256("unknown profile");
        bytes32 bad = specs.registerSpecification(keccak256("unknown"), Policy.SPECIFICATION, "", profiles);
        vm.expectRevert(ASFCapacityMarket.InvalidSafetyConfiguration.selector);
        new ASFCapacityMarket(capacity, token, safety, specs, bad, guardian);
        profiles[0] = Policy.PROFILE;
        bad = specs.registerSpecification(keccak256("wrong doc"), keccak256("unimplemented"), "", profiles);
        vm.expectRevert(ASFCapacityMarket.InvalidSafetyConfiguration.selector);
        new ASFCapacityMarket(capacity, token, safety, specs, bad, guardian);
    }

    function test_ASFPaymentCallbackSuspensionRollsBackEntireConfirmation() public {
        guardian = address(token); // Only this adversarial fixture makes the token the guardian.
        _install();
        uint256 id = _hold();
        token.setHook(
            address(safety),
            abi.encodeCall(safety.suspend, (root, T.RESTRICT_FULL_STOP, bytes32(0), bytes32(0)))
        );
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.confirm(id);
        _status(id, CapacityReservations.Status.Held);
        eq(token.balanceOf(BUYER), 100_000);
        eq(market.escrowLiability(), 0);
        eq(uint256(safety.bindingOf(root).state), uint256(T.BindingState.Active));
        token.setHook(address(0), "");
        vm.prank(BUYER);
        market.confirm(id);
        _sums();
    }

    function test_ASFFullStopPreservesBuyerCancellationButNotNewCommitments() public {
        uint256 id = _book();
        _pause(root, T.RESTRICT_FULL_STOP);
        vm.prank(PROVIDER);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        market.cancel(id);
        vm.prank(BUYER);
        market.cancel(id);
        eq(token.balanceOf(BUYER), 100_000);
        _status(id, CapacityReservations.Status.Released);
        vm.prank(BUYER);
        vm.expectPartialRevert(ASFCapacityMarket.SafetyDenied.selector);
        market.hold(pool, 1, 1_500);
        vm.expectRevert(MarketEscrow.InvalidState.selector);
        market.claimRefund(id);
        _sums();
    }

    function test_ASFFullStopPreservesDirectReleaseAndThirdPartyExpiryRecovery() public {
        uint256 released = _book();
        uint256 expired = _book();
        _pause(root, T.RESTRICT_FULL_STOP);
        vm.prank(BUYER);
        capacity.release(released);
        market.claimRefund(released);
        vm.warp(END);
        capacity.expire(expired);
        market.claimRefund(expired);
        eq(token.balanceOf(BUYER), 100_000);
        _sums();
    }

    function test_ASFAlreadySubmittedResultRetainsBuyerSettlementAuthority() public {
        uint256 id = _book();
        vm.warp(START);
        _admit(id);
        vm.prank(PROVIDER);
        market.submit(id, keccak256("report"));
        _pause(root, T.RESTRICT_FULL_STOP);
        vm.prank(guardian);
        vm.expectRevert(MarketEscrow.Unauthorized.selector);
        market.accept(id);
        vm.prank(BUYER);
        market.accept(id);
        eq(token.balanceOf(PROVIDER), 100);
        eq(capacity.getPool(pool).consumed, 1);
        _sums();
    }

    function testDemo_ASFSuspensionKeepsRefundAndExplicitContinuationDistinct() public {
        uint256 cancelId = _book();
        uint256 workId = _book();
        _pause(root, T.RESTRICT_NO_NEW_RISK | T.RESTRICT_DERISK_ONLY);
        vm.prank(BUYER);
        market.cancel(cancelId);
        emit log_named_uint("Buyer refund while parent is suspended", 100);
        _resume(root);
        vm.warp(START);
        _admit(workId);
        _pause(root, T.RESTRICT_NO_NEW_RISK | T.RESTRICT_ESSENTIAL_ONLY);
        vm.prank(PROVIDER);
        market.submit(workId, keccak256("completed report"));
        _resume(root);
        _pause(root, T.RESTRICT_FULL_STOP);
        vm.prank(BUYER);
        market.accept(workId);
        emit log_named_uint(
            "Payment for already-submitted work under independent order authority", token.balanceOf(PROVIDER)
        );
        emit log_named_uint("Consumed quota remains consumed", capacity.getPool(pool).consumed);
        _sums();
    }
}
