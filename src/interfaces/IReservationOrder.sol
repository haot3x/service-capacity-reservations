// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Experimental order view, not an assigned ERC interface.
interface IReservationOrder {
    struct Binding {
        address provider;
        address beneficiary;
        bytes32 serviceHash;
        bytes32 termsHash;
        uint256 poolId;
        uint64 units;
        uint64 windowStart;
        uint64 windowEnd;
        bytes32 orderId;
        bool funded;
    }

    function reservationOrder(uint256 reservationId) external view returns (Binding memory);
}
