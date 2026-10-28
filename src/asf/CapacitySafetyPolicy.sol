// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Hashes of the committed canonical local policy documents; tested against their exact bytes.
library CapacitySafetyPolicy {
    bytes32 internal constant SPECIFICATION =
        0xbba7d2e6f01c38011997b2a962199b11a58bf0f97eda297c20cb4c7097280326;
    bytes32 internal constant PARAMETERS = 0xefcdaaa57438e9af638e597357cf7d32bcc20d52b864d4529236afddc4a1281b;
    bytes32 internal constant PROFILE = keccak256("x:finch:capacity-safety@2");
}
