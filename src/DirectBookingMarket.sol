// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapacityReservations} from "./CapacityReservations.sol";
import {MarketEscrow} from "./MarketEscrow.sol";

/// @notice Direct buyer transaction entry point; buyer is always msg.sender.
contract DirectBookingMarket is MarketEscrow {
    mapping(address => uint256) public nonces;

    constructor(CapacityReservations registry_, IERC20 token_) MarketEscrow(registry_, token_) {}

    function hold(uint256 poolId, uint64 units, uint64 holdUntil) external nonReentrant returns (uint256) {
        bytes32 requestId = keccak256(abi.encode(msg.sender, nonces[msg.sender]++));
        return _hold(poolId, msg.sender, units, holdUntil, requestId);
    }
}
