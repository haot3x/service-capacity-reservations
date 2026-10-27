// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.26;

/// @notice Interface from the Final ERC-2135 specification; interface ID 0xdd691946.
interface IERC2135 {
    function consume(address consumer, uint256 assetId, uint256 amount, bytes calldata data)
        external
        returns (bool success);

    function isConsumableBy(address consumer, uint256 assetId, uint256 amount)
        external
        view
        returns (bool consumable);

    event OnConsumption(address indexed consumer, uint256 indexed assetId, uint256 amount, bytes data);
}
