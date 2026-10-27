// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC2135} from "./interfaces/IERC2135.sol";
import {IReservationOrder} from "./interfaces/IReservationOrder.sol";

/// @title Custodial service inventory and reservations
/// @author Ted (@haot3x)
/// @notice Local prototype. Pool inventory and receipt IDs share one ERC-1155 ID namespace.
contract CapacityReservations is ERC1155Supply, ERC1155Holder, ReentrancyGuard, IERC2135 {
    enum Status {
        None,
        Held,
        Confirmed,
        Consumed,
        Released,
        Expired
    }

    struct PoolConfig {
        bytes32 serviceHash;
        bytes32 termsHash;
        uint64 capacity;
        uint64 windowStart;
        uint64 windowEnd;
        uint64 maxHoldDuration;
    }

    struct Pool {
        address provider;
        PoolConfig config;
        uint64 held;
        uint64 confirmed;
        uint64 consumed;
    }

    struct Reservation {
        uint256 poolId;
        address beneficiary;
        address adapter;
        uint64 units;
        uint64 holdUntil;
        Status status;
        address orderContract;
        bytes32 orderId;
    }

    error UnknownPool();
    error UnknownReservation();
    error InvalidPool();
    error Unauthorized();
    error InvalidHold();
    error InsufficientCapacity();
    error RequestAlreadyUsed();
    error InvalidState();
    error DeadlinePassed();
    error TooEarly();
    error InvalidOrder();
    error OrderAlreadyBound();
    error NotConsumable();
    error ForeignToken();

    event PoolCreated(
        uint256 indexed poolId, address indexed provider, PoolConfig config, address[] adapters
    );
    event ReservationHeld(
        uint256 indexed reservationId,
        uint256 indexed poolId,
        address indexed beneficiary,
        address adapter,
        uint64 units,
        uint64 holdUntil,
        bytes32 requestId
    );
    event ReservationConfirmed(uint256 indexed reservationId, address indexed orderContract, bytes32 orderId);
    event ReservationClosed(uint256 indexed reservationId, uint256 indexed poolId, Status status);

    uint256 private _nextId = 1;
    mapping(uint256 => Pool) private _pools;
    mapping(uint256 => Reservation) private _reservations;
    mapping(uint256 => mapping(address => bool)) public adapterAllowed;
    mapping(uint256 => uint256) public adapterCount;
    mapping(address => mapping(bytes32 => bool)) public requestUsed;
    mapping(bytes32 => bool) public orderBound;

    constructor() ERC1155("") {}

    function createPool(PoolConfig calldata config, address[] calldata adapters)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (
            config.capacity == 0 || config.serviceHash == bytes32(0) || config.termsHash == bytes32(0)
                || config.maxHoldDuration == 0 || block.timestamp >= config.windowStart
                || config.windowStart >= config.windowEnd || adapters.length == 0 || adapters.length > 16
        ) {
            revert InvalidPool();
        }
        id = _nextId++;
        _pools[id] = Pool(msg.sender, config, 0, 0, 0);
        adapterCount[id] = adapters.length;
        for (uint256 i; i < adapters.length; ++i) {
            address adapter = adapters[i];
            if (adapter.code.length == 0 || adapterAllowed[id][adapter]) revert InvalidPool();
            adapterAllowed[id][adapter] = true;
        }
        // All inventory stays in custody. The contract never approves an external token operator.
        _mint(address(this), id, config.capacity, "");
        emit PoolCreated(id, msg.sender, config, adapters);
    }

    function getPool(uint256 poolId) public view returns (Pool memory) {
        Pool memory pool = _pools[poolId];
        if (pool.provider == address(0)) revert UnknownPool();
        return pool;
    }

    function getReservation(uint256 id) public view returns (Reservation memory) {
        Reservation memory reservation = _reservations[id];
        if (reservation.status == Status.None) revert UnknownReservation();
        return reservation;
    }

    /// @notice Conservative stored availability; expired holds need explicit cleanup.
    function availability(uint256 poolId) external view returns (uint256 units, bool bookingOpen) {
        Pool memory pool = getPool(poolId);
        return (balanceOf(address(this), poolId), block.timestamp < pool.config.windowStart);
    }

    function hold(uint256 poolId, address beneficiary, uint64 units, uint64 holdUntil, bytes32 requestId)
        external
        nonReentrant
        returns (uint256 id)
    {
        Pool memory pool = getPool(poolId);
        if (!adapterAllowed[poolId][msg.sender]) revert Unauthorized();
        if (
            beneficiary == address(0) || units == 0 || requestId == bytes32(0)
                || block.timestamp >= pool.config.windowStart || holdUntil <= block.timestamp
                || holdUntil > pool.config.windowStart
                || uint256(holdUntil) - block.timestamp > pool.config.maxHoldDuration
        ) revert InvalidHold();
        if (requestUsed[msg.sender][requestId]) revert RequestAlreadyUsed();
        if (balanceOf(address(this), poolId) < units) revert InsufficientCapacity();
        requestUsed[msg.sender][requestId] = true;
        id = _nextId++;
        _reservations[id] = Reservation(
            poolId, beneficiary, msg.sender, units, holdUntil, Status.Held, address(0), bytes32(0)
        );
        _pools[poolId].held += units;
        // Convert available pool units into a uniquely addressable custodial receipt.
        _burn(address(this), poolId, units);
        _mint(address(this), id, units, "");
        emit ReservationHeld(id, poolId, beneficiary, msg.sender, units, holdUntil, requestId);
    }

    function confirm(uint256 id, bytes32 orderId) external nonReentrant {
        Reservation storage r = _reservations[id];
        if (r.status == Status.None) revert UnknownReservation();
        if (msg.sender != r.adapter) revert Unauthorized();
        if (r.status != Status.Held) revert InvalidState();
        if (block.timestamp >= r.holdUntil) revert DeadlinePassed();
        if (orderId == bytes32(0)) revert InvalidOrder();
        bytes32 key = keccak256(abi.encode(msg.sender, orderId));
        if (orderBound[key]) revert OrderAlreadyBound();
        r.orderContract = msg.sender;
        r.orderId = orderId;
        if (!_orderMatches(id, r)) revert InvalidOrder();
        orderBound[key] = true;
        r.status = Status.Confirmed;
        Pool storage pool = _pools[r.poolId];
        pool.held -= r.units;
        pool.confirmed += r.units;
        emit ReservationConfirmed(id, msg.sender, orderId);
    }

    /// @notice Asset ID is the reservation receipt ID, not the available-inventory pool ID.
    function isConsumableBy(address consumer, uint256 id, uint256 amount) public view returns (bool) {
        Reservation memory r = _reservations[id];
        if (r.status != Status.Confirmed || consumer != r.beneficiary || amount != r.units) return false;
        PoolConfig memory config = _pools[r.poolId].config;
        return
            block.timestamp >= config.windowStart && block.timestamp < config.windowEnd
                && _orderMatches(id, r);
    }

    /// @param data Canonical abi.encode(orderContract, orderId); partial use is unsupported.
    function consume(address consumer, uint256 id, uint256 amount, bytes calldata data)
        external
        nonReentrant
        returns (bool)
    {
        Reservation storage r = _reservations[id];
        if (r.status == Status.None) revert UnknownReservation();
        if (msg.sender != r.adapter) revert Unauthorized();
        if (data.length != 64 || keccak256(data) != keccak256(abi.encode(r.orderContract, r.orderId))) {
            revert InvalidOrder();
        }
        if (!isConsumableBy(consumer, id, amount)) revert NotConsumable();
        r.status = Status.Consumed;
        Pool storage pool = _pools[r.poolId];
        pool.confirmed -= r.units;
        pool.consumed += r.units;
        // ERC-1155 emits the real burn TransferSingle required by ERC-2135.
        _burn(address(this), id, amount);
        emit OnConsumption(consumer, id, amount, data);
        emit ReservationClosed(id, r.poolId, Status.Consumed);
        return true;
    }

    function release(uint256 id) external nonReentrant {
        Reservation memory r = getReservation(id);
        if (msg.sender != r.beneficiary && msg.sender != r.adapter) revert Unauthorized();
        if (r.status == Status.Held) {
            if (block.timestamp >= r.holdUntil) revert DeadlinePassed();
        } else if (r.status == Status.Confirmed) {
            if (block.timestamp >= _pools[r.poolId].config.windowStart) revert DeadlinePassed();
        } else {
            revert InvalidState();
        }
        _closeUnused(id, r, Status.Released);
    }

    function expire(uint256 id) external nonReentrant {
        Reservation memory r = getReservation(id);
        if (r.status == Status.Held) {
            if (block.timestamp < r.holdUntil) revert TooEarly();
        } else if (r.status == Status.Confirmed) {
            if (block.timestamp < _pools[r.poolId].config.windowEnd) revert TooEarly();
        } else {
            revert InvalidState();
        }
        _closeUnused(id, r, Status.Expired);
    }

    function _closeUnused(uint256 id, Reservation memory r, Status status) private {
        _reservations[id].status = status;
        Pool storage pool = _pools[r.poolId];
        if (r.status == Status.Held) pool.held -= r.units;
        else pool.confirmed -= r.units;
        _burn(address(this), id, r.units);
        _mint(address(this), r.poolId, r.units, "");
        emit ReservationClosed(id, r.poolId, status);
    }

    function _orderMatches(uint256 id, Reservation memory r) private view returns (bool) {
        Pool memory pool = _pools[r.poolId];
        try IReservationOrder(r.adapter).reservationOrder(id) returns (IReservationOrder.Binding memory b) {
            return b.funded && b.provider == pool.provider && b.beneficiary == r.beneficiary
                && b.serviceHash == pool.config.serviceHash && b.termsHash == pool.config.termsHash
                && b.poolId == r.poolId && b.units == r.units && b.windowStart == pool.config.windowStart
                && b.windowEnd == pool.config.windowEnd && b.orderId == r.orderId;
        } catch {
            return false;
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC1155Holder)
        returns (bool)
    {
        return interfaceId == type(IERC2135).interfaceId || super.supportsInterface(interfaceId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(this)) revert ForeignToken();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(this)) revert ForeignToken();
        return this.onERC1155BatchReceived.selector;
    }
}
