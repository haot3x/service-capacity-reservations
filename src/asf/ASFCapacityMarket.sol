// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CapacityReservations} from "../CapacityReservations.sol";
import {DirectBookingMarket} from "../DirectBookingMarket.sol";
import {ASFTypes as T} from "../../vendor/asf/ASFTypes.sol";
import {ASFKeys} from "../../vendor/asf/libraries/ASFKeys.sol";
import {IASFBindingRegistry} from "../../vendor/asf/interfaces/IASFBindingRegistry.sol";
import {IASFSpecificationRegistry} from "../../vendor/asf/interfaces/IASFSpecificationRegistry.sol";
import {CapacitySafetyPolicy as Policy} from "./CapacitySafetyPolicy.sol";

/// @author Ted (@haot3x)
/// @notice Local consumer of pinned ASF revision 7. Provider suspension covers commitments and delivery;
///         established escrow recovery and settlement have a separate, pre-accepted authority.
contract ASFCapacityMarket is DirectBookingMarket {
    IASFBindingRegistry public immutable safetyRegistry;
    IASFSpecificationRegistry public immutable specifications;
    bytes32 public immutable specificationId;
    address public immutable guardian;
    mapping(uint256 => bytes32) public poolBinding;

    error InvalidSafetyConfiguration();
    error SafetyNotConfigured();
    error SafetyAlreadyConfigured();
    error SafetyAuthorityMismatch();
    error SafetyDenied(T.Verdict verdict, T.Reason reason, uint8 restrictions);

    event PoolSafetyConfigured(uint256 indexed poolId, bytes32 indexed bindingId, bytes32 requirementId);

    constructor(
        CapacityReservations capacity,
        IERC20 token,
        IASFBindingRegistry bindings,
        IASFSpecificationRegistry specs,
        bytes32 specId,
        address guardian_
    ) DirectBookingMarket(capacity, token) {
        if (address(bindings).code.length == 0 || address(specs).code.length == 0 || guardian_ == address(0))
        {
            revert InvalidSafetyConfiguration();
        }
        T.SpecificationVersion memory version = specs.versionOf(specId, 1);
        if (
            version.contentHash != Policy.SPECIFICATION || version.requiredProfiles.length != 1
                || version.requiredProfiles[0] != Policy.PROFILE
        ) revert InvalidSafetyConfiguration();
        safetyRegistry = bindings;
        specifications = specs;
        specificationId = specId;
        guardian = guardian_;
    }

    /// @notice Provider pins one valid binding forever, before this market can issue any holds.
    function configureSafety(uint256 poolId, bytes32 bindingId) external {
        CapacityReservations.Pool memory pool = registry.getPool(poolId);
        if (msg.sender != pool.provider) revert Unauthorized();
        if (poolBinding[poolId] != bytes32(0)) revert SafetyAlreadyConfigured();
        if (
            bindingId == bytes32(0) || pool.provider == guardian || registry.adapterCount(poolId) != 1
                || !registry.adapterAllowed(poolId, address(this))
        ) revert InvalidSafetyConfiguration();
        _verifyAuthorityChain(poolId, bindingId);
        (T.Verdict verdict, T.Reason reason, uint8 restrictions) = _check(poolId, bindingId);
        if (verdict != T.Verdict.Satisfied) revert SafetyDenied(verdict, reason, restrictions);
        poolBinding[poolId] = bindingId;
        emit PoolSafetyConfigured(poolId, bindingId, safetyRegistry.requirementId(requirement(poolId)));
    }

    /// @notice Canonical one-member JSON scope, distinct for each chain/market/registry/pool.
    function scopeKey(uint256 poolId) public view returns (bytes32) {
        string memory ref = string.concat(
            ASFKeys.accountRef(block.chainid, address(this)),
            "/capacity/",
            ASFKeys.accountRef(block.chainid, address(registry)),
            "/",
            Strings.toString(poolId)
        );
        return ASFKeys.refScopeKey(ref);
    }

    /// @notice Resolved against the actual immutable provider and pool, not trusted as a claim by itself.
    function authorityRef(uint256 poolId) public view returns (bytes32) {
        return
            keccak256(abi.encode(block.chainid, address(registry), poolId, registry.getPool(poolId).provider));
    }

    function requirement(uint256 poolId) public view returns (T.RequirementSet memory req) {
        T.Clause[] memory clauses = new T.Clause[](1);
        uint32[] memory versions = new uint32[](1);
        versions[0] = 1;
        T.Intervener[] memory interveners = new T.Intervener[](1);
        interveners[0] = T.Intervener(guardian, T.RIGHT_SUSPEND | T.RIGHT_RESUME);
        address provider = registry.getPool(poolId).provider;
        clauses[0] = T.Clause(
            address(specifications),
            specificationId,
            versions,
            provider,
            ASFKeys.accountSubjectKey(provider),
            scopeKey(poolId),
            T.ENFORCED_CONTRACT,
            interveners
        );
        return T.RequirementSet(T.Combinator.All, 0, clauses);
    }

    function safetyState(uint256 poolId) public view returns (T.Verdict, T.Reason, uint8) {
        bytes32 id = poolBinding[poolId];
        if (id == bytes32(0)) revert SafetyNotConfigured();
        _verifyAuthorityChain(poolId, id);
        return _check(poolId, id);
    }

    function _authorizeNewRisk(uint256 poolId) internal view override {
        (T.Verdict verdict, T.Reason reason, uint8 restrictions) = safetyState(poolId);
        if (verdict != T.Verdict.Satisfied) revert SafetyDenied(verdict, reason, restrictions);
    }

    function _authorizeDelivery(uint256 poolId) internal view override {
        (T.Verdict verdict, T.Reason reason, uint8 restrictions) = safetyState(poolId);
        if (verdict == T.Verdict.Satisfied) return;
        // This profile knows exactly two continuation sets. DERISK_ONLY is not a delivery permission.
        bool continuation = restrictions == T.RESTRICT_ESSENTIAL_ONLY
            || restrictions == (T.RESTRICT_ESSENTIAL_ONLY | T.RESTRICT_NO_NEW_RISK);
        if (
            verdict == T.Verdict.NotSatisfied && continuation && _standingStopAbsent(poolId)
                && _responseDocumentsAbsent(poolBinding[poolId])
                && (reason == T.Reason.Suspended || reason == T.Reason.ParentNotSatisfied)
        ) return;
        revert SafetyDenied(verdict, reason, restrictions);
    }

    /// @dev A Suspended leaf is evaluated before standing stops in revision 7. Check the stop independently
    ///      before granting our optional continuation; the first failure reason alone cannot authorize it.
    function _standingStopAbsent(uint256 poolId) private view returns (bool) {
        address provider = registry.getPool(poolId).provider;
        try safetyRegistry.stopOf(
            provider, ASFKeys.accountSubjectKey(provider), address(specifications), specificationId, guardian
        ) returns (
            T.Stop memory stop
        ) {
            return stop.bindingId == bytes32(0);
        } catch {
            return false;
        }
    }

    function _check(uint256 poolId, bytes32 id) private view returns (T.Verdict, T.Reason, uint8) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        try safetyRegistry.check(requirement(poolId), ids) returns (
            T.Verdict verdict, T.Reason[] memory reasons, uint8[] memory restrictions
        ) {
            if (reasons.length == 1 && restrictions.length == 1) {
                return (verdict, reasons[0], restrictions[0]);
            }
        } catch {}
        return (T.Verdict.Unknown, T.Reason.SpecRegistryUnavailable, 0);
    }

    /// @dev A deliberately narrow attenuation profile: no wider/different parameters or authority on parents.
    function _verifyAuthorityChain(uint256 poolId, bytes32 id) private view {
        address provider = registry.getPool(poolId).provider;
        bytes32 scope = scopeKey(poolId);
        bytes32 authority = authorityRef(poolId);
        bytes32 subject = ASFKeys.accountSubjectKey(provider);
        for (uint256 depth; id != bytes32(0); ++depth) {
            if (depth > T.MAX_DEPTH) revert SafetyAuthorityMismatch();
            T.Binding memory binding = safetyRegistry.bindingOf(id);
            if (
                binding.adopter != provider || binding.subjectKey != subject || binding.scopeKey != scope
                    || binding.authorityRef != authority || binding.paramsHash != Policy.PARAMETERS
                    || binding.specRegistry != address(specifications) || binding.specId != specificationId
                    || binding.version != 1 || binding.contentHash != Policy.SPECIFICATION
            ) {
                revert SafetyAuthorityMismatch();
            }
            // The leaf requirement alone does not constrain who can resume an ancestor.
            T.Intervener[] memory interveners = safetyRegistry.intervenersOf(id);
            bool guardianPresent;
            for (uint256 i; i < interveners.length; ++i) {
                if (interveners[i].account == guardian) {
                    uint8 requiredRights = T.RIGHT_SUSPEND | T.RIGHT_RESUME;
                    guardianPresent = interveners[i].rights & requiredRights == requiredRights;
                } else if (interveners[i].rights & T.RIGHT_RESUME != 0) {
                    revert SafetyAuthorityMismatch();
                }
            }
            if (!guardianPresent) revert SafetyAuthorityMismatch();
            id = binding.parentBindingId;
        }
    }

    /// @dev Nonzero response documents are not interpreted by this prototype. Unknown restrictions never pass.
    function _responseDocumentsAbsent(bytes32 id) private view returns (bool) {
        for (uint256 depth; id != bytes32(0); ++depth) {
            if (depth > T.MAX_DEPTH) return false;
            T.Binding memory binding = safetyRegistry.bindingOf(id);
            if (binding.state == T.BindingState.Suspended && binding.responseRef != bytes32(0)) return false;
            id = binding.parentBindingId;
        }
        return true;
    }
}
