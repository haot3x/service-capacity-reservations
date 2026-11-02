// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CapacityReservations as Inventory} from "../CapacityReservations.sol";
import {DirectBookingMarket} from "../DirectBookingMarket.sol";
import {SealedBidTender} from "../../vendor/erc8469/src/SealedBidTender.sol";
import {ISealedBidTender, AwardProfiles} from "../../vendor/erc8469/src/ISealedBidTender.sol";
import {IAwardMechanism} from "../../vendor/erc8469/src/IAwardMechanism.sol";
import {PostedPriceAward} from "../../vendor/erc8469/src/mechanisms/PostedPriceAward.sol";

/// @dev The actual commit entry point reserves capacity before the upstream core accepts the bid.
contract CapacityAdmittedTender is SealedBidTender {
    ReservedTenderMarket public immutable capacityMarket;
    bool private entering;

    constructor(ReservedTenderMarket market) {
        capacityMarket = market;
    }

    function commitBid(bytes32 id, bytes32 commitment) public payable override {
        require(!entering, "admission reentry");
        entering = true;
        capacityMarket.admitBid(id, msg.sender);
        super.commitBid(id, commitment);
        entering = false;
    }
}

/// @author Ted (@haot3x)
/// @notice Experimental allocation-only posted-price integration. Real auction, inventory and
/// booking escrow; no ERC-8414 kernel, physical-capacity proof or execution-binding guarantee.
contract ReservedTenderMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Open,
        FundedOrder,
        Closed
    }

    struct Job {
        address buyer;
        bytes32 poolTerms;
        uint64 units;
        uint64 start;
        uint256 amount;
        uint256 reservationId;
        State state;
    }

    DirectBookingMarket public immutable booking;
    Inventory public immutable inventory;
    IERC20 public immutable token;
    CapacityAdmittedTender public immutable tender;
    PostedPriceAward public immutable mechanism;
    uint256 public pendingFunds;
    uint256 private nonce;
    mapping(bytes32 => Job) public jobs;
    mapping(bytes32 => mapping(address => uint256)) public bidPool;
    mapping(bytes32 => mapping(address => uint256)) public bidReservation;
    mapping(uint256 => bool) public released;

    error InvalidJob();
    error Unauthorized();
    error InvalidBid();
    error WrongPhase();
    error TokenMovement();

    event CapacityTenderOpened(bytes32 indexed tenderId, address indexed buyer, bytes32 contentHash);
    event CapacityBidReserved(bytes32 indexed tenderId, address indexed bidder, uint256 reservationId);
    event CapacityAwardBound(bytes32 indexed tenderId, uint256 reservationId);

    constructor(DirectBookingMarket booking_) {
        booking = booking_;
        inventory = booking_.registry();
        token = booking_.paymentToken();
        tender = new CapacityAdmittedTender(this);
        mechanism = new PostedPriceAward();
    }

    function _poolTerms(uint256 poolId) private view returns (bytes32) {
        Inventory.Pool memory p = inventory.getPool(poolId);
        (uint256 price, uint64 settlement) = booking.offers(poolId);
        return keccak256(
            abi.encode(
                p.config.serviceHash,
                p.config.termsHash,
                p.config.windowStart,
                p.config.windowEnd,
                price,
                settlement
            )
        );
    }

    /// @notice Buyer fixes the service/interval/price and prefunds the order; no bidder is chosen here.
    function open(uint256 templatePool, uint64 units, uint64 commitDeadline, uint64 revealDeadline)
        external
        nonReentrant
        returns (bytes32 id)
    {
        Inventory.Pool memory pool = inventory.getPool(templatePool);
        (uint256 price,) = booking.offers(templatePool);
        if (price == 0 || units == 0 || revealDeadline >= pool.config.windowStart) revert InvalidJob();
        Job memory job = Job(
            msg.sender, _poolTerms(templatePool), units, pool.config.windowStart, price * units, 0, State.Open
        );
        bytes32 targetId = bytes32(++nonce);
        bytes32 content = _content(targetId, job);
        _take(msg.sender, job.amount);
        pendingFunds += job.amount;
        id = tender.openTender(
            ISealedBidTender.TenderTerms({
                targetRef: keccak256(abi.encode(block.chainid, address(this), targetId)),
                mechanism: address(mechanism),
                reserve: job.amount,
                units: 1,
                commitDeadline: commitDeadline,
                revealDeadline: revealDeadline,
                bond: 0,
                bondAsset: address(0),
                slashRecipient: address(0),
                maxBidders: 16,
                integrationProfile: AwardProfiles.ALLOCATION_ONLY,
                contentHash: content
            })
        );
        jobs[id] = job;
        emit CapacityTenderOpened(id, msg.sender, content);
    }

    function _content(bytes32 targetId, Job memory job) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                "capacity-posted-price-v1",
                block.chainid,
                address(this),
                address(booking),
                address(token),
                targetId,
                job.buyer,
                job.poolTerms,
                job.units,
                job.amount
            )
        );
    }

    /// @notice Only the real pool provider selects inventory for its own bid.
    function selectPool(bytes32 id, uint256 poolId) external nonReentrant {
        if (jobs[id].state != State.Open || bidReservation[id][msg.sender] != 0) revert InvalidBid();
        if (inventory.getPool(poolId).provider != msg.sender) revert Unauthorized();
        if (_poolTerms(poolId) != jobs[id].poolTerms) revert InvalidBid();
        bidPool[id][msg.sender] = poolId;
    }

    function admitBid(bytes32 id, address bidder) external nonReentrant {
        if (msg.sender != address(tender)) revert Unauthorized();
        Job memory job = jobs[id];
        uint256 poolId = bidPool[id][bidder];
        if (
            job.state != State.Open || poolId == 0 || bidReservation[id][bidder] != 0
                || block.timestamp >= job.start || inventory.getPool(poolId).provider != bidder
                || _poolTerms(poolId) != job.poolTerms
        ) revert InvalidBid();
        // This contract is the custody beneficiary. Neither bidder nor buyer can release a live bid directly.
        uint256 reservation = booking.hold(poolId, job.units, job.start);
        bidReservation[id][bidder] = reservation;
        emit CapacityBidReserved(id, bidder, reservation);
    }

    function _final(bytes32 id) private view returns (IAwardMechanism.Award[] memory awards) {
        ISealedBidTender.Phase phase = tender.phaseOf(id);
        if (phase != ISealedBidTender.Phase.Awarded && phase != ISealedBidTender.Phase.Void) {
            revert WrongPhase();
        }
        return tender.awardOf(id);
    }

    /// @notice Permissionless handoff to the existing booking escrow, using the original reservation.
    function settle(bytes32 id) external nonReentrant {
        Job storage job = jobs[id];
        if (job.state != State.Open || block.timestamp >= job.start) revert WrongPhase();
        IAwardMechanism.Award[] memory awards = _final(id);
        if (awards.length != 1 || awards[0].price != job.amount) revert InvalidJob();
        uint256 reservation = bidReservation[id][awards[0].winner];
        if (reservation == 0 || released[reservation]) revert InvalidBid();
        job.reservationId = reservation;
        job.state = State.FundedOrder;
        pendingFunds -= job.amount;
        token.forceApprove(address(booking), job.amount);
        booking.confirm(reservation);
        token.forceApprove(address(booking), 0);
        emit CapacityAwardBound(id, reservation);
    }

    function releaseBid(bytes32 id, address bidder) external nonReentrant {
        IAwardMechanism.Award[] memory awards = _final(id);
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].winner == bidder) revert WrongPhase();
        }
        _release(bidReservation[id][bidder]);
    }

    function _release(uint256 reservation) private {
        if (reservation == 0 || released[reservation]) revert InvalidBid();
        Inventory.Reservation memory r = inventory.getReservation(reservation);
        if (r.status == Inventory.Status.Held) {
            if (block.timestamp >= r.holdUntil) inventory.expire(reservation);
            else inventory.release(reservation);
        } else if (r.status != Inventory.Status.Expired) {
            revert WrongPhase();
        }
        released[reservation] = true;
    }

    /// @notice Allocation-only boundary: no guaranteed execution after the service window starts.
    /// A delayed/unfinalized tender cannot strand the buyer's prefunding.
    function refundUnexecuted(bytes32 id) external nonReentrant {
        Job storage job = jobs[id];
        if (job.state != State.Open) revert WrongPhase();
        if (block.timestamp < job.start && tender.phaseOf(id) != ISealedBidTender.Phase.Void) {
            revert WrongPhase();
        }
        job.state = State.Closed;
        pendingFunds -= job.amount;
        _pay(job.buyer, job.amount);
    }

    function accept(bytes32 id) external nonReentrant {
        Job storage job = jobs[id];
        if (job.state != State.FundedOrder || msg.sender != job.buyer) revert Unauthorized();
        job.state = State.Closed;
        booking.accept(job.reservationId);
    }

    function cancel(bytes32 id) external nonReentrant {
        Job storage job = jobs[id];
        if (job.state != State.FundedOrder || msg.sender != job.buyer) revert Unauthorized();
        job.state = State.Closed;
        booking.cancel(job.reservationId);
        _pay(job.buyer, job.amount);
    }

    function reject(bytes32 id) external nonReentrant {
        Job storage job = jobs[id];
        if (job.state != State.FundedOrder || msg.sender != job.buyer) revert Unauthorized();
        job.state = State.Closed;
        booking.reject(job.reservationId);
        _pay(job.buyer, job.amount);
    }

    function refundOrder(bytes32 id) external nonReentrant {
        Job storage job = jobs[id];
        if (job.state != State.FundedOrder) revert WrongPhase();
        job.state = State.Closed;
        booking.claimRefund(job.reservationId);
        _pay(job.buyer, job.amount);
    }

    function _take(address buyer, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 buyerBefore = token.balanceOf(buyer);
        token.safeTransferFrom(buyer, address(this), amount);
        if (
            token.balanceOf(address(this)) != beforeBalance + amount || buyerBefore < amount
                || token.balanceOf(buyer) != buyerBefore - amount
        ) revert TokenMovement();
    }

    function _pay(address buyer, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 buyerBefore = token.balanceOf(buyer);
        token.safeTransfer(buyer, amount);
        if (
            beforeBalance < amount || token.balanceOf(address(this)) != beforeBalance - amount
                || token.balanceOf(buyer) != buyerBefore + amount
        ) revert TokenMovement();
    }
}
