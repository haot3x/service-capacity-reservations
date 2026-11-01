// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestSupport} from "./TestSupport.sol";
import {CapacityReservations as Inventory} from "../src/CapacityReservations.sol";
import {IReservationOrder} from "../src/interfaces/IReservationOrder.sol";

/// @notice Test-only target. Funding and task changes are explicitly mocked, not an ERC-8414 kernel.
contract TenderTargetHarness {
    address public immutable admission;
    address public immutable provider;
    bytes32 public contentHash;
    uint64 public immutable units;
    uint64 public immutable windowStart;
    uint64 public immutable windowEnd;
    uint256 public reservationId;
    bool public funded = true;
    bool public failBind;

    constructor(
        address admission_,
        address provider_,
        bytes32 content_,
        uint64 units_,
        uint64 start_,
        uint64 end_
    ) {
        admission = admission_;
        provider = provider_;
        contentHash = content_;
        units = units_;
        windowStart = start_;
        windowEnd = end_;
    }

    function setContent(bytes32 value) external {
        contentHash = value;
    }

    function setFunded(bool value) external {
        funded = value;
    }

    function setFailBind(bool value) external {
        failBind = value;
    }

    function bind(uint256 id) external {
        require(msg.sender == admission && reservationId == 0 && !failBind, "target refuses binding");
        reservationId = id;
    }
}

/// @author Ted (@haot3x)
/// @notice Test-only single-tender admission model. The controller supplies final outcomes in place of
/// an ERC-8469 award engine. This tests inventory composition, not auction eligibility or economics.
contract TenderAdmissionHarness is IReservationOrder {
    enum Phase {
        Open,
        Admitted,
        Won,
        Lost,
        Void,
        Bound,
        Released
    }

    Inventory public immutable inventory;
    address public immutable controller;
    uint64 public immutable executeBefore;
    uint256 public poolId;
    TenderTargetHarness public target;
    bytes32 public contentHash;
    bytes32 public commitment;
    uint64 public units;
    uint256 public reservationId;
    Phase public phase;

    error InvalidAdmission();
    error InvalidTransition();
    error TargetChanged();

    constructor(Inventory inventory_, uint64 executeBefore_) {
        inventory = inventory_;
        controller = msg.sender;
        executeBefore = executeBefore_;
    }

    function configure(uint256 pool, TenderTargetHarness target_) external {
        require(msg.sender == controller && poolId == 0, "configure once");
        Inventory.Pool memory p = inventory.getPool(pool);
        require(
            target_.admission() == address(this) && target_.provider() == p.provider
                && target_.windowStart() == p.config.windowStart && target_.windowEnd() == p.config.windowEnd
                && target_.contentHash() != bytes32(0) && executeBefore > block.timestamp
                && executeBefore < p.config.windowStart,
            "invalid target terms"
        );
        poolId = pool;
        target = target_;
        contentHash = target_.contentHash();
        units = target_.units();
    }

    function admit(bytes32 bidCommitment) external {
        Inventory.Pool memory p = inventory.getPool(poolId);
        if (
            msg.sender != p.provider || phase != Phase.Open || bidCommitment == bytes32(0)
                || block.timestamp >= executeBefore
        ) revert InvalidAdmission();
        if (target.contentHash() != contentHash) revert TargetChanged();
        bytes32 requestId = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                poolId,
                p.provider,
                address(target),
                contentHash,
                units,
                p.config.windowStart,
                p.config.windowEnd,
                bidCommitment
            )
        );
        // Custody is deliberate: a bidder cannot independently cancel inventory backing a live commitment.
        reservationId = inventory.hold(poolId, address(this), units, executeBefore, requestId);
        commitment = bidCommitment;
        phase = Phase.Admitted;
    }

    function finalize(Phase outcome) external {
        if (
            msg.sender != controller || phase != Phase.Admitted
                || (outcome != Phase.Won && outcome != Phase.Lost && outcome != Phase.Void)
                || (outcome == Phase.Won && block.timestamp >= executeBefore)
        ) revert InvalidTransition();
        phase = outcome;
    }

    function releaseFinal() external {
        if (phase != Phase.Lost && phase != Phase.Void) revert InvalidTransition();
        Inventory.Reservation memory r = inventory.getReservation(reservationId);
        if (r.status == Inventory.Status.Held) {
            if (block.timestamp < r.holdUntil) inventory.release(reservationId);
            else inventory.expire(reservationId);
        } else if (r.status != Inventory.Status.Expired) {
            revert InvalidTransition();
        }
        phase = Phase.Released;
    }

    function execute() external {
        if (phase != Phase.Won || block.timestamp >= executeBefore) revert InvalidTransition();
        if (target.contentHash() != contentHash) revert TargetChanged();
        // Both writes roll back on failure. The original reservation becomes confirmed; it is never released
        // and reacquired between the award and target binding.
        target.bind(reservationId);
        inventory.confirm(reservationId, orderId());
        phase = Phase.Bound;
    }

    function orderId() public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), address(target), contentHash));
    }

    function reservationOrder(uint256 id) external view returns (Binding memory b) {
        if (id != reservationId || id == 0) return b;
        Inventory.Pool memory p = inventory.getPool(poolId);
        return Binding({
            provider: p.provider,
            beneficiary: address(this),
            serviceHash: p.config.serviceHash,
            termsHash: p.config.termsHash,
            poolId: poolId,
            units: units,
            windowStart: p.config.windowStart,
            windowEnd: p.config.windowEnd,
            orderId: orderId(),
            funded: target.funded() && target.reservationId() == id && target.contentHash() == contentHash
        });
    }
}

contract TenderAdmissionTest is TestSupport {
    Inventory private inventory;
    TenderAdmissionHarness private first;
    TenderAdmissionHarness private second;
    TenderTargetHarness private firstTarget;
    TenderTargetHarness private secondTarget;
    address private constant PROVIDER = address(0xA11CE);
    uint64 private constant EXECUTE_BEFORE = 1_500;
    uint64 private constant START = 2_000;
    uint64 private constant END = 3_000;
    uint256 private pool;

    function setUp() public {
        vm.warp(1_000);
        inventory = new Inventory();
        first = new TenderAdmissionHarness(inventory, EXECUTE_BEFORE);
        second = new TenderAdmissionHarness(inventory, EXECUTE_BEFORE);
        firstTarget = new TenderTargetHarness(address(first), PROVIDER, keccak256("task A"), 1, START, END);
        secondTarget = new TenderTargetHarness(address(second), PROVIDER, keccak256("task B"), 1, START, END);
        address[] memory adapters = new address[](2);
        adapters[0] = address(first);
        adapters[1] = address(second);
        vm.prank(PROVIDER);
        pool = inventory.createPool(
            Inventory.PoolConfig({
                serviceHash: keccak256("research report"),
                termsHash: keccak256("service terms"),
                capacity: 1,
                windowStart: START,
                windowEnd: END,
                maxHoldDuration: 1_000
            }),
            adapters
        );
        first.configure(pool, firstTarget);
        second.configure(pool, secondTarget);
    }

    function _admit(TenderAdmissionHarness tender) private {
        vm.prank(PROVIDER);
        tender.admit(keccak256("sealed bid"));
    }

    function _assertInventory(uint256 free, uint256 held, uint256 confirmed) private view {
        (uint256 available,) = inventory.availability(pool);
        Inventory.Pool memory p = inventory.getPool(pool);
        eq(available, free);
        eq(p.held, held);
        eq(p.confirmed, confirmed);
        eq(free + p.held + p.confirmed + p.consumed, 1);
    }

    function test_SecondOverlappingTenderFailsBeforeCommitmentIsAccepted() public {
        _admit(first);
        vm.prank(PROVIDER);
        vm.expectRevert(Inventory.InsufficientCapacity.selector);
        second.admit(keccak256("second sealed bid"));
        eq(uint256(second.phase()), uint256(TenderAdmissionHarness.Phase.Open));
        eq(second.reservationId(), 0);
        yes(second.commitment() == bytes32(0));
        _assertInventory(0, 1, 0);
    }

    function test_WinnerRetainsSameReservationThroughTargetBinding() public {
        _admit(first);
        uint256 id = first.reservationId();
        first.finalize(TenderAdmissionHarness.Phase.Won);
        _assertInventory(0, 1, 0);
        first.execute();
        eq(firstTarget.reservationId(), id);
        eq(first.reservationId(), id);
        Inventory.Reservation memory r = inventory.getReservation(id);
        eq(uint256(r.status), uint256(Inventory.Status.Confirmed));
        eq(r.orderContract, address(first));
        yes(r.orderId == first.orderId());
        _assertInventory(0, 0, 1);
        vm.warp(EXECUTE_BEFORE);
        vm.expectRevert(Inventory.TooEarly.selector);
        inventory.expire(id);
        vm.prank(PROVIDER);
        vm.expectRevert(Inventory.Unauthorized.selector);
        inventory.release(id);
        vm.warp(END);
        inventory.expire(id);
        _assertInventory(1, 0, 0);
    }

    function test_LoserReleasesOnlyAfterFinalOutcome() public {
        _admit(first);
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.releaseFinal();
        first.finalize(TenderAdmissionHarness.Phase.Lost);
        first.releaseFinal();
        _admit(second);
        _assertInventory(0, 1, 0);
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.releaseFinal();
    }

    function test_VoidReleasesReservation() public {
        _admit(first);
        first.finalize(TenderAdmissionHarness.Phase.Void);
        first.releaseFinal();
        _assertInventory(1, 0, 0);
    }

    function test_WinnerCannotReleaseBeforeOrAfterBinding() public {
        _admit(first);
        first.finalize(TenderAdmissionHarness.Phase.Won);
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.releaseFinal();
        first.execute();
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.releaseFinal();
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.execute();
        _assertInventory(0, 0, 1);
    }

    function test_FailedFundingCheckRollsBackTargetWriteAndPreservesHold() public {
        _admit(first);
        first.finalize(TenderAdmissionHarness.Phase.Won);
        firstTarget.setFunded(false);
        vm.expectRevert(Inventory.InvalidOrder.selector);
        first.execute();
        eq(firstTarget.reservationId(), 0);
        eq(uint256(first.phase()), uint256(TenderAdmissionHarness.Phase.Won));
        no(inventory.orderBound(keccak256(abi.encode(address(first), first.orderId()))));
        _assertInventory(0, 1, 0);
        firstTarget.setFunded(true);
        first.execute();
        _assertInventory(0, 0, 1);
    }

    function test_TargetFailurePreservesHold() public {
        _admit(first);
        first.finalize(TenderAdmissionHarness.Phase.Won);
        firstTarget.setFailBind(true);
        vm.expectRevert();
        first.execute();
        eq(firstTarget.reservationId(), 0);
        _assertInventory(0, 1, 0);
    }

    function test_ChangedTaskCannotUseOriginalReservation() public {
        _admit(first);
        first.finalize(TenderAdmissionHarness.Phase.Won);
        firstTarget.setContent(keccak256("task A version 2"));
        vm.expectRevert(TenderAdmissionHarness.TargetChanged.selector);
        first.execute();
        eq(firstTarget.reservationId(), 0);
        _assertInventory(0, 1, 0);
    }

    function test_BidderCannotCancelLiveCommitmentThroughLedger() public {
        _admit(first);
        uint256 id = first.reservationId();
        vm.prank(PROVIDER);
        vm.expectRevert(Inventory.Unauthorized.selector);
        inventory.release(id);
        _assertInventory(0, 1, 0);
    }

    function test_ExpiredHoldCannotBecomeExecutableAward() public {
        _admit(first);
        first.finalize(TenderAdmissionHarness.Phase.Won);
        vm.warp(EXECUTE_BEFORE);
        inventory.expire(first.reservationId());
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.execute();
        eq(firstTarget.reservationId(), 0);
        _assertInventory(1, 0, 0);
    }

    function test_LateFinalOutcomeCannotAwardExpiredCapacity() public {
        _admit(first);
        vm.warp(EXECUTE_BEFORE);
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.finalize(TenderAdmissionHarness.Phase.Won);
        first.finalize(TenderAdmissionHarness.Phase.Void);
        first.releaseFinal();
        _assertInventory(1, 0, 0);
    }

    function test_OnlyProviderCanCommitAndControllerCanSupplyOutcome() public {
        vm.expectRevert(TenderAdmissionHarness.InvalidAdmission.selector);
        first.admit(keccak256("unauthorized"));
        _admit(first);
        vm.prank(PROVIDER);
        vm.expectRevert(TenderAdmissionHarness.InvalidTransition.selector);
        first.finalize(TenderAdmissionHarness.Phase.Won);
    }
}
