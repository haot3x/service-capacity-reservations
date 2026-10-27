// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Hashes of the committed canonical local policy documents; tested against their exact bytes.
library CapacitySafetyPolicy {
    bytes32 internal constant SPECIFICATION =
        0x66974e5985ea1a3a2c4add1f3015222c3cc6ea6dbafc396deb76cbd6c7991cc4;
    bytes32 internal constant PARAMETERS = 0x6704efdcb0a75cd358b888559e10e37cf9e1f10a1a9b3375049096304196d6d9;
    bytes32 internal constant PROFILE = keccak256("x:finch:capacity-safety@1");
}
