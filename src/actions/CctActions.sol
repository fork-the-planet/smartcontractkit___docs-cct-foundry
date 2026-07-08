// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts@5.3.0/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IAccessControl} from "@openzeppelin/contracts@5.3.0/access/IAccessControl.sol";

/// @title CctActions
/// @notice The shared action layer: every CCT write operation is defined here exactly once, as a pure
///         builder that returns `Call[]` structs (`target`, `value`, `data`) encoded with `abi.encodeCall`
///         on the real contract interfaces — never a hand-written 4-byte selector.
/// @dev Scripts stay thin wrappers: they parse inputs (env vars / JSON) exactly as before, call the
///      matching builder, and hand the result to an executor (`EoaExecutor` broadcasts it as an EOA).
///      Because an operation is one function returning `Call[]`, later execution modes (multisig batch,
///      timelock schedule/execute) can reuse the identical calldata without re-implementing any operation.
///      Every call is `value: 0` (CCT governance operations are never payable) and targets a deployed
///      contract resolved by the caller — no addresses are hardcoded inside the action layer.
library CctActions {
    /// @notice One on-chain call: the canonical action record shared by all execution modes.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev Wraps a single encoded call into a one-element `Call[]`.
    function _one(address target, bytes memory data) private pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: data});
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Registration (claim + accept the CCIP token admin)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claim the CCIP token admin via `RegistryModuleOwnerCustom.registerAdminViaOwner`.
    ///         The executing account must be the token's `owner()` (the module self-register check).
    /// @dev The owner-vs-getCCIPAdmin probe stays script-side (`ClaimAdmin` auto-detects which claim
    ///      path the token supports); the action layer carries one builder per claim path.
    function registerAdminViaOwner(address registryModule, address token) internal pure returns (Call[] memory) {
        return _one(registryModule, abi.encodeCall(RegistryModuleOwnerCustom.registerAdminViaOwner, (token)));
    }

    /// @notice Claim the CCIP token admin via `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
    ///         The executing account must be the token's `getCCIPAdmin()`.
    function registerAdminViaGetCCIPAdmin(address registryModule, address token) internal pure returns (Call[] memory) {
        return _one(registryModule, abi.encodeCall(RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin, (token)));
    }

    /// @notice Accept the pending CCIP token admin role on the TokenAdminRegistry (step 2 of the claim).
    ///         The executing account must be the pending administrator.
    function acceptAdminRole(address tokenAdminRegistry, address token) internal pure returns (Call[] memory) {
        return _one(tokenAdminRegistry, abi.encodeCall(TokenAdminRegistry.acceptAdminRole, (token)));
    }

    /// @notice Claim (via `registerAdminViaOwner`) and accept the CCIP token admin as ONE atomic batch.
    /// @dev The claim sets the registry's pending administrator to the calling account, so an
    ///      `acceptAdminRole` executed by the same account in the same batch succeeds — the two-step
    ///      registration collapses into one submission when both calls share the executing account.
    function registerAndAcceptAdminViaOwner(address registryModule, address tokenAdminRegistry, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return concat(registerAdminViaOwner(registryModule, token), acceptAdminRole(tokenAdminRegistry, token));
    }

    /// @notice Claim (via `registerAdminViaGetCCIPAdmin`) and accept the CCIP token admin as ONE atomic
    ///         batch. Same pending-administrator reasoning as `registerAndAcceptAdminViaOwner`.
    function registerAndAcceptAdminViaGetCCIPAdmin(address registryModule, address tokenAdminRegistry, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return concat(registerAdminViaGetCCIPAdmin(registryModule, token), acceptAdminRole(tokenAdminRegistry, token));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pool lane configuration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add/remove/update remote chains on a token pool via `applyChainUpdates`.
    /// @dev Takes ALREADY-ENCODED remote pool and token bytes inside `ChainUpdate` (EVM:
    ///      `abi.encode(address)`; SVM: raw 32 bytes) so the chain-family encoding stays in
    ///      `ChainHandlers` — the action layer never interprets remote addresses.
    function applyChainUpdates(address pool, uint64[] memory removes, TokenPool.ChainUpdate[] memory updates)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.applyChainUpdates, (removes, updates)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TokenAdminRegistry administration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Point a token at its pool in the TokenAdminRegistry (the registry cutover).
    ///         The executing account must be the token's registry administrator.
    function setPool(address tokenAdminRegistry, address token, address pool) internal pure returns (Call[] memory) {
        return _one(tokenAdminRegistry, abi.encodeCall(TokenAdminRegistry.setPool, (token, pool)));
    }

    /// @notice Transfer the registry administrator role to a new address (step 1 of two; the new
    ///         administrator must `acceptAdminRole`).
    function transferAdminRole(address tokenAdminRegistry, address token, address newAdmin)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(tokenAdminRegistry, abi.encodeCall(TokenAdminRegistry.transferAdminRole, (token, newAdmin)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ownership (pool / hooks / lockbox / Ownable tokens)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Initiate an ownership transfer on any `IOwnable` contract (Chainlink `ConfirmedOwner`
    ///         and OZ `Ownable`/`Ownable2Step` share this signature). Two-step variants require the new
    ///         owner to `acceptOwnership`; plain OZ `Ownable` transfers immediately.
    function transferOwnership(address target, address newOwner) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IOwnable.transferOwnership, (newOwner)));
    }

    /// @notice Complete a two-step ownership transfer. The executing account must be the pending owner.
    function acceptOwnership(address target) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IOwnable.acceptOwnership, ()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Token admin handoff (AccessControl token variants)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Begin the default-admin transfer on an `AccessControlDefaultAdminRules` token (e.g.
    ///         `CrossChainToken`). Step 1 of two; the new admin accepts after the configured delay.
    function beginDefaultAdminTransfer(address token, address newAdmin) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IAccessControlDefaultAdminRules.beginDefaultAdminTransfer, (newAdmin)));
    }

    /// @notice Accept a pending default-admin transfer. The executing account must be the pending
    ///         default admin and the transfer delay must have elapsed.
    function acceptDefaultAdminTransfer(address token) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IAccessControlDefaultAdminRules.acceptDefaultAdminTransfer, ()));
    }

    /// @notice Grant an AccessControl role.
    function grantRole(address target, bytes32 role, address account) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IAccessControl.grantRole, (role, account)));
    }

    /// @notice Revoke an AccessControl role.
    function revokeRole(address target, bytes32 role, address account) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IAccessControl.revokeRole, (role, account)));
    }

    /// @notice Atomically hand an AccessControl role from `oldHolder` to `newHolder` (grant first, then
    ///         revoke, in one batch) — the plain-AccessControl token admin handoff, which has no
    ///         two-step accept.
    function handOffRole(address target, bytes32 role, address newHolder, address oldHolder)
        internal
        pure
        returns (Call[] memory)
    {
        return concat(grantRole(target, role, newHolder), revokeRole(target, role, oldHolder));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Composition
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Flatten two `Call[]`s into one batch (atomic execution set).
    function concat(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory out) {
        out = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 j = 0; j < b.length; j++) {
            out[a.length + j] = b[j];
        }
    }
}
