// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts@5.3.0/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IAccessControl} from "@openzeppelin/contracts@5.3.0/access/IAccessControl.sol";
import {Ownable2Step} from "@openzeppelin/contracts@5.3.0/access/Ownable2Step.sol";

/**
 * @notice Initiates an ownership transfer for a token, token pool, pool hooks, or lockbox.
 * @dev This is step 1 of a two-step process — the new owner must run AcceptOwnership to complete it.
 *      For tokenPool, poolHooks, and lockBox: uses Chainlink's ConfirmedOwner (Ownable2Step) pattern.
 *      For token: auto-detects the token type and calls the appropriate function:
 *        - CrossChainToken (AccessControlDefaultAdminRules): beginDefaultAdminTransfer — step 1 of 2
 *        - OZ Ownable2Step:                                  transferOwnership         — step 1 of 2
 *        - ConfirmedOwner / plain Ownable:                   transferOwnership         — step 1 of 2
 *          Note: ConfirmedOwner requires AcceptOwnership; plain Ownable transfers immediately (no accept).
 *        - BurnMintERC20 v1 (plain AccessControl, no owner()): grantRole + revokeRole — 1-step, atomic
 *
 * Required env vars:
 *   ENTITY_TYPE — one of: token, tokenPool, poolHooks, lockBox
 *   ADDRESS     — contract address of the entity
 *   NEW_OWNER   — address of the new owner/admin
 *
 * Usage:
 *   ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=tokenPool ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=token ADDRESS=0xYourToken NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=poolHooks ADDRESS=0xYourHooks NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=lockBox ADDRESS=0xYourLockBox NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * If ENTITY_TYPE is omitted, the contract at ADDRESS is treated as a generic IOwnable (same as tokenPool/poolHooks/lockBox).
 */
contract TransferOwnership is Script {
    HelperConfig public helperConfig;

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function _entityLabel(string memory entityType) internal pure returns (string memory) {
        if (bytes(entityType).length == 0) return "Contract";
        if (_eq(entityType, "token")) return "Token";
        if (_eq(entityType, "tokenPool")) return "Token Pool";
        if (_eq(entityType, "poolHooks")) return "Pool Hooks";
        if (_eq(entityType, "lockBox")) return "LockBox";
        revert(
            string.concat(
                "Invalid ENTITY_TYPE \"", entityType, "\". Valid values: token, tokenPool, poolHooks, lockBox"
            )
        );
    }

    function _entityActionLabel(string memory entityType) internal pure returns (string memory) {
        if (bytes(entityType).length == 0) return "contract";
        if (_eq(entityType, "token")) return "token";
        if (_eq(entityType, "tokenPool")) return "token pool";
        if (_eq(entityType, "poolHooks")) return "pool hooks";
        return "lockbox"; // lockBox
    }

    function _padRight(string memory s, uint256 targetLen) internal pure returns (string memory) {
        bytes memory sb = bytes(s);
        if (sb.length >= targetLen) return s;
        bytes memory result = new bytes(targetLen);
        uint256 i;
        for (i = 0; i < sb.length; i++) {
            result[i] = sb[i];
        }
        for (; i < targetLen; i++) {
            result[i] = 0x20; // space
        }
        return string(result);
    }

    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        string memory entityType = vm.envOr("ENTITY_TYPE", string(""));
        string memory label = _entityLabel(entityType); // also validates entityType

        address entityAddress = vm.envAddress("ADDRESS");
        require(entityAddress != address(0), "ADDRESS must be set to a non-zero address");

        address newOwner = vm.envAddress("NEW_OWNER");
        require(newOwner != address(0), "NEW_OWNER must be set to a non-zero address");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"🔄 Transfer ", label, " Ownership"));
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       Transfer ", _entityActionLabel(entityType), " ownership"));
        console.log("========================================");
        console.log("");

        if (_eq(entityType, "token")) {
            _transferTokenOwnership(chainId, chainName, entityAddress, newOwner);
        } else {
            _transferSimpleOwnership(chainId, chainName, entityType, label, entityAddress, newOwner);
        }
    }

    function _transferSimpleOwnership(
        uint256 chainId,
        string memory chainName,
        string memory entityType,
        string memory label,
        address entityAddress,
        address newOwner
    ) internal {
        IOwnable entity = IOwnable(entityAddress);
        address currentOwner = entity.owner();

        console.log(string.concat("Transfer ", label, " Ownership Parameters:"));
        console.log(string.concat("  ", _padRight(string.concat(label, ":"), 14), " ", vm.toString(entityAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));
        console.log(string.concat("  New Owner:     ", vm.toString(newOwner)));

        vm.startBroadcast();

        (, address broadcaster,) = vm.readCallers();
        console.log(string.concat("  Signer:        ", vm.toString(broadcaster)));
        console.log("");

        require(
            currentOwner == broadcaster,
            string.concat(
                "Signer (",
                vm.toString(broadcaster),
                ") is not the current ",
                _entityActionLabel(entityType),
                " owner (",
                vm.toString(currentOwner),
                "). Only the current owner can initiate an ownership transfer."
            )
        );

        console.log(
            string.concat("\n[Step 1] Transferring ", _entityActionLabel(entityType), " ownership on ", chainName)
        );
        entity.transferOwnership(newOwner);
        console.log(string.concat(unicode"✅ ", label, " ownership transfer initiated successfully!"));

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ ", label, " Ownership Transfer Initiated on ", chainName, "!"));
        console.log("========================================");
        console.log(
            string.concat(
                _padRight(string.concat(label, ":"), 12),
                " ",
                helperConfig.getExplorerUrl(chainId, "/address/", entityAddress)
            )
        );
        console.log(string.concat("New Owner:   ", vm.toString(newOwner)));
        console.log("========================================");
        console.log("");
        string memory entityTypeHint = bytes(entityType).length > 0
            ? string.concat("ENTITY_TYPE=", entityType, " ADDRESS=", vm.toString(entityAddress))
            : string.concat("ADDRESS=", vm.toString(entityAddress));
        console.log(
            string.concat(
                unicode"ℹ️  The new owner (",
                vm.toString(newOwner),
                ") must run AcceptOwnership with ",
                entityTypeHint,
                " to complete the transfer."
            )
        );
        console.log("");
    }

    function _transferTokenOwnership(uint256 chainId, string memory chainName, address tokenAddress, address newOwner)
        internal
    {
        // Auto-detect token type by probing view functions unique to each standard.
        // 1. CrossChainToken (AccessControlDefaultAdminRules) — has pendingDefaultAdmin()
        // 2. OZ Ownable2Step                                  — has pendingOwner() + owner()
        // 3. ConfirmedOwner / plain Ownable                   — has owner() but no pendingOwner()
        // 4. Old BurnMintERC20 v1 (plain AccessControl)       — has neither
        bool isCrossChainToken = false;
        bool isOwnable2Step = false;
        bool isOwnable = false;
        try IAccessControlDefaultAdminRules(tokenAddress).pendingDefaultAdmin() returns (address, uint48) {
            isCrossChainToken = true;
        } catch {}

        if (!isCrossChainToken) {
            try IOwnable(tokenAddress).owner() returns (address) {
                // Has owner() — now check for pendingOwner() to distinguish Ownable2Step from plain Ownable/ConfirmedOwner
                try Ownable2Step(tokenAddress).pendingOwner() returns (address) {
                    isOwnable2Step = true;
                } catch {
                    isOwnable = true; // ConfirmedOwner or plain Ownable
                }
            } catch {}
        }

        address currentOwner;
        if (isCrossChainToken) {
            currentOwner = IAccessControlDefaultAdminRules(tokenAddress).defaultAdmin();
        } else if (isOwnable2Step || isOwnable) {
            currentOwner = IOwnable(tokenAddress).owner();
        } // else: old AccessControl — validated inside broadcast via hasRole

        if (isCrossChainToken) {
            console.log(
                unicode"ℹ️  Detection: CrossChainToken (AccessControlDefaultAdminRules) — using beginDefaultAdminTransfer (step 1 of 2)"
            );
        } else if (isOwnable2Step) {
            console.log(unicode"ℹ️  Detection: OZ Ownable2Step — using transferOwnership (step 1 of 2)");
        } else if (isOwnable) {
            console.log(
                unicode"ℹ️  Detection: Ownable (owner() only, no pendingOwner()) — ConfirmedOwner or plain Ownable"
            );
            console.log(
                unicode"ℹ️  transferOwnership will be called. If ConfirmedOwner: run AcceptOwnership after. If plain Ownable: transfer completes immediately."
            );
        } else {
            console.log(
                unicode"ℹ️  Detection: AccessControl (BurnMintERC20 v1) — using grantRole + revokeRole (1-step, atomic, no accept required)"
            );
        }
        console.log("");

        console.log("Transfer Token Ownership Parameters:");
        console.log(string.concat("  Token:         ", vm.toString(tokenAddress)));
        if (isCrossChainToken || isOwnable2Step || isOwnable) {
            console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));
        }
        console.log(string.concat("  New Owner:     ", vm.toString(newOwner)));

        vm.startBroadcast();

        (, address broadcaster,) = vm.readCallers();
        console.log(string.concat("  Signer:        ", vm.toString(broadcaster)));
        console.log("");

        if (isCrossChainToken || isOwnable2Step || isOwnable) {
            require(
                currentOwner == broadcaster,
                string.concat(
                    "Signer (",
                    vm.toString(broadcaster),
                    ") is not the current token owner/admin (",
                    vm.toString(currentOwner),
                    "). Only the current owner/admin can initiate an ownership transfer."
                )
            );
        }

        if (isCrossChainToken) {
            console.log(string.concat("\n[Step 1] Initiating admin transfer (CrossChainToken) on ", chainName));
            IAccessControlDefaultAdminRules(tokenAddress).beginDefaultAdminTransfer(newOwner);
            console.log(unicode"✅ Admin transfer initiated! New owner must run AcceptOwnership.");
        } else if (isOwnable2Step || isOwnable) {
            console.log(string.concat("\n[Step 1] Transferring token ownership on ", chainName));
            IOwnable(tokenAddress).transferOwnership(newOwner);
            if (isOwnable2Step) {
                console.log(unicode"✅ Ownership transfer initiated! New owner must run AcceptOwnership.");
            } else {
                console.log(
                    unicode"✅ Ownership transfer initiated! If ConfirmedOwner: new owner must run AcceptOwnership. If plain Ownable: transfer is already complete."
                );
            }
        } else {
            // Old BurnMintERC20 v1: plain AccessControl — grant to new admin, revoke from self, atomically.
            bytes32 adminRole = bytes32(0); // DEFAULT_ADMIN_ROLE is always bytes32(0)
            require(
                IAccessControl(tokenAddress).hasRole(adminRole, broadcaster),
                string.concat("Signer (", vm.toString(broadcaster), ") does not have DEFAULT_ADMIN_ROLE on this token.")
            );
            console.log(string.concat("\n[Step 1] Granting DEFAULT_ADMIN_ROLE to new owner on ", chainName));
            IAccessControl(tokenAddress).grantRole(adminRole, newOwner);
            console.log(string.concat("[Step 2] Revoking DEFAULT_ADMIN_ROLE from current admin on ", chainName));
            IAccessControl(tokenAddress).revokeRole(adminRole, broadcaster);
            console.log(unicode"✅ Admin role transferred atomically! No accept step required.");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Token Ownership Transfer Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token:       ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("New Owner:   ", vm.toString(newOwner)));
        console.log("========================================");
        console.log("");
        if (isCrossChainToken || isOwnable2Step || isOwnable) {
            console.log(
                string.concat(
                    unicode"ℹ️  The new owner (",
                    vm.toString(newOwner),
                    ") must run AcceptOwnership with ENTITY_TYPE=token ADDRESS=",
                    vm.toString(tokenAddress),
                    " to complete the transfer (unless this token uses plain Ownable, in which case transfer is already complete)."
                )
            );
        }
        console.log("");
    }
}
