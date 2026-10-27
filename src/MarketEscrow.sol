// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CapacityReservations} from "./CapacityReservations.sol";
import {IReservationOrder} from "./interfaces/IReservationOrder.sol";

/// @notice Experimental buyer-evaluated escrow shared by two different booking entry points.
/// @dev This is not an ERC-8183/8414 implementation. Only the configured exact-transfer token is supported.
abstract contract MarketEscrow is ReentrancyGuard, IReservationOrder {
    using SafeERC20 for IERC20;

    enum OrderStatus {
        None,
        Funded,
        Admitted,
        Submitted,
        Settled,
        Refunded
    }

    struct Offer {
        uint256 unitPrice;
        uint64 settlementDeadline;
    }

    struct Order {
        Binding binding;
        uint256 amount;
        uint64 settlementDeadline;
        OrderStatus status;
        bytes32 resultHash;
    }

    error Unauthorized();
    error InvalidOffer();
    error InvalidOrder();
    error UnknownOrder();
    error InvalidState();
    error DeadlinePassed();
    error RefundUnavailable();
    error UnexpectedTokenMovement();

    event OfferConfigured(uint256 indexed poolId, uint256 unitPrice, uint64 settlementDeadline);
    event OrderFunded(uint256 indexed reservationId, address indexed buyer, uint256 amount);
    event OrderAdmitted(uint256 indexed reservationId);
    event ResultSubmitted(uint256 indexed reservationId, bytes32 resultHash);
    event OrderPaid(uint256 indexed reservationId, address indexed recipient, uint256 amount, bool refund);

    CapacityReservations public immutable registry;
    IERC20 public immutable paymentToken;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Order) internal _orders;
    uint256 public escrowLiability;

    constructor(CapacityReservations registry_, IERC20 paymentToken_) {
        if (address(registry_).code.length == 0 || address(paymentToken_).code.length == 0) {
            revert InvalidOffer();
        }
        registry = registry_;
        paymentToken = paymentToken_;
    }

    /// @notice One immutable provider-approved price/deadline per pool and marketplace.
    function configure(uint256 poolId, uint256 unitPrice, uint64 settlementDeadline) external {
        CapacityReservations.Pool memory pool = registry.getPool(poolId);
        if (msg.sender != pool.provider) revert Unauthorized();
        if (
            !registry.adapterAllowed(poolId, address(this)) || offers[poolId].unitPrice != 0 || unitPrice == 0
                || settlementDeadline <= pool.config.windowEnd
        ) revert InvalidOffer();
        offers[poolId] = Offer(unitPrice, settlementDeadline);
        emit OfferConfigured(poolId, unitPrice, settlementDeadline);
    }

    function _hold(uint256 poolId, address buyer, uint64 units, uint64 holdUntil, bytes32 requestId)
        internal
        returns (uint256)
    {
        if (offers[poolId].unitPrice == 0) revert InvalidOffer();
        _authorizeNewRisk(poolId);
        return registry.hold(poolId, buyer, units, holdUntil, requestId);
    }

    function getOrder(uint256 reservationId) public view returns (Order memory order) {
        order = _orders[reservationId];
        if (order.status == OrderStatus.None) revert UnknownOrder();
    }

    function reservationOrder(uint256 reservationId) external view returns (Binding memory b) {
        Order memory order = getOrder(reservationId);
        b = order.binding;
        b.funded = order.status == OrderStatus.Funded;
    }

    /// @notice Buyer consents through msg.sender and funds the whole immutable quoted price.
    function confirm(uint256 reservationId) external nonReentrant {
        CapacityReservations.Reservation memory r = registry.getReservation(reservationId);
        if (r.adapter != address(this) || r.beneficiary != msg.sender) revert Unauthorized();
        if (r.status != CapacityReservations.Status.Held || _orders[reservationId].status != OrderStatus.None)
        {
            revert InvalidState();
        }
        CapacityReservations.Pool memory pool = registry.getPool(r.poolId);
        _authorizeNewRisk(r.poolId);
        Offer memory offer = offers[r.poolId];
        uint256 amount = offer.unitPrice * r.units;
        Binding memory binding = Binding(
            pool.provider,
            r.beneficiary,
            pool.config.serviceHash,
            pool.config.termsHash,
            r.poolId,
            r.units,
            pool.config.windowStart,
            pool.config.windowEnd,
            bytes32(reservationId),
            true
        );
        _orders[reservationId] =
            Order(binding, amount, offer.settlementDeadline, OrderStatus.Funded, bytes32(0));
        escrowLiability += amount;
        uint256 vaultBefore = paymentToken.balanceOf(address(this));
        uint256 buyerBefore = paymentToken.balanceOf(msg.sender);
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        if (
            paymentToken.balanceOf(address(this)) != vaultBefore + amount || buyerBefore < amount
                || paymentToken.balanceOf(msg.sender) != buyerBefore - amount
        ) {
            revert UnexpectedTokenMovement();
        }
        // Any late deadline, binding, or registry failure reverts the payment and order too.
        // Token callbacks can change external policy state; recheck at the point of confirmation.
        _authorizeNewRisk(r.poolId);
        registry.confirm(reservationId, binding.orderId);
        emit OrderFunded(reservationId, msg.sender, amount);
    }

    function admit(uint256 reservationId) public virtual nonReentrant {
        Order storage order = _requireOrder(reservationId);
        if (msg.sender != order.binding.provider) revert Unauthorized();
        if (order.status != OrderStatus.Funded) revert InvalidState();
        _authorizeNewRisk(order.binding.poolId);
        registry.consume(
            order.binding.beneficiary,
            reservationId,
            order.binding.units,
            abi.encode(address(this), order.binding.orderId)
        );
        order.status = OrderStatus.Admitted;
        emit OrderAdmitted(reservationId);
    }

    function submit(uint256 reservationId, bytes32 resultHash) external nonReentrant {
        Order storage order = _requireOrder(reservationId);
        if (msg.sender != order.binding.provider) revert Unauthorized();
        if (order.status != OrderStatus.Admitted || resultHash == bytes32(0)) revert InvalidState();
        if (block.timestamp >= order.settlementDeadline) revert DeadlinePassed();
        _authorizeDelivery(order.binding.poolId);
        order.resultHash = resultHash;
        order.status = OrderStatus.Submitted;
        emit ResultSubmitted(reservationId, resultHash);
    }

    /// @notice Buyer acts as evaluator in this demonstration; this is an explicit trust assumption.
    function accept(uint256 reservationId) external nonReentrant {
        Order storage order = _requireOrder(reservationId);
        if (msg.sender != order.binding.beneficiary) revert Unauthorized();
        if (order.status != OrderStatus.Submitted) revert InvalidState();
        if (block.timestamp >= order.settlementDeadline) revert DeadlinePassed();
        _pay(reservationId, order, false);
    }

    function reject(uint256 reservationId) external nonReentrant {
        Order storage order = _requireOrder(reservationId);
        if (msg.sender != order.binding.beneficiary) revert Unauthorized();
        if (order.status != OrderStatus.Submitted) revert InvalidState();
        _pay(reservationId, order, true);
    }

    /// @notice Before work-window start, release inventory and refund in one transaction.
    function cancel(uint256 reservationId) external nonReentrant {
        Order storage order = _requireOrder(reservationId);
        if (msg.sender != order.binding.beneficiary) revert Unauthorized();
        if (order.status != OrderStatus.Funded) revert InvalidState();
        registry.release(reservationId);
        _pay(reservationId, order, true);
    }

    /// @notice Anyone can trigger recovery; funds always go to the original buyer.
    function claimRefund(uint256 reservationId) external nonReentrant {
        Order storage order = _requireOrder(reservationId);
        if (order.status == OrderStatus.Funded) {
            CapacityReservations.Reservation memory r = registry.getReservation(reservationId);
            if (
                r.status == CapacityReservations.Status.Confirmed
                    && block.timestamp >= order.binding.windowEnd
            ) {
                registry.expire(reservationId);
                r.status = CapacityReservations.Status.Expired;
            }
            if (
                r.status != CapacityReservations.Status.Released
                    && r.status != CapacityReservations.Status.Expired
            ) {
                revert RefundUnavailable();
            }
        } else if (order.status == OrderStatus.Admitted || order.status == OrderStatus.Submitted) {
            if (block.timestamp < order.settlementDeadline) revert RefundUnavailable();
        } else {
            revert InvalidState();
        }
        _pay(reservationId, order, true);
    }

    function _pay(uint256 id, Order storage order, bool refund) private {
        address recipient = refund ? order.binding.beneficiary : order.binding.provider;
        uint256 amount = order.amount;
        order.status = refund ? OrderStatus.Refunded : OrderStatus.Settled;
        escrowLiability -= amount;
        uint256 vaultBefore = paymentToken.balanceOf(address(this));
        uint256 recipientBefore = paymentToken.balanceOf(recipient);
        paymentToken.safeTransfer(recipient, amount);
        if (
            vaultBefore < amount || paymentToken.balanceOf(address(this)) != vaultBefore - amount
                || paymentToken.balanceOf(recipient) != recipientBefore + amount
        ) revert UnexpectedTokenMovement();
        emit OrderPaid(id, recipient, amount, refund);
    }

    function _requireOrder(uint256 id) private view returns (Order storage order) {
        order = _orders[id];
        if (order.status == OrderStatus.None) revert UnknownOrder();
    }

    /// @dev Optional execution-time policy. Original markets retain their original behavior.
    function _authorizeNewRisk(uint256 poolId) internal view virtual {}

    /// @dev Distinct from new admission; refunds and settlement keep their own order authority.
    function _authorizeDelivery(uint256 poolId) internal view virtual {}
}
