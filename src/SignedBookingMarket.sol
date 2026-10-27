// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {CapacityReservations} from "./CapacityReservations.sol";
import {MarketEscrow} from "./MarketEscrow.sol";

/// @notice Relayed, buyer-signed holds; confirmation/payment still require the buyer's transaction.
contract SignedBookingMarket is MarketEscrow, EIP712 {
    struct HoldRequest {
        address buyer;
        uint256 poolId;
        uint64 units;
        uint64 holdUntil;
        uint256 nonce;
        uint64 validUntil;
    }

    bytes32 public constant HOLD_TYPEHASH = keccak256(
        "HoldRequest(address buyer,uint256 poolId,uint64 units,uint64 holdUntil,uint256 nonce,uint64 validUntil)"
    );
    mapping(address => uint256) public nonces;
    error InvalidSignature();

    constructor(CapacityReservations registry_, IERC20 token_)
        MarketEscrow(registry_, token_)
        EIP712("Service Capacity Holds", "1")
    {}

    function holdDigest(HoldRequest calldata request) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    HOLD_TYPEHASH,
                    request.buyer,
                    request.poolId,
                    request.units,
                    request.holdUntil,
                    request.nonce,
                    request.validUntil
                )
            )
        );
    }

    function holdSigned(HoldRequest calldata request, bytes calldata signature)
        external
        nonReentrant
        returns (uint256)
    {
        if (
            request.buyer == address(0) || request.nonce != nonces[request.buyer]
                || block.timestamp >= request.validUntil || request.validUntil > request.holdUntil
                || !SignatureChecker.isValidSignatureNow(request.buyer, holdDigest(request), signature)
        ) {
            revert InvalidSignature();
        }
        nonces[request.buyer]++;
        bytes32 requestId = keccak256(abi.encode(request.buyer, request.nonce));
        return _hold(request.poolId, request.buyer, request.units, request.holdUntil, requestId);
    }
}
