// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts@5.3.0/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Ownable2Step} from "@openzeppelin/contracts@5.3.0/access/Ownable2Step.sol";

/**
 * @notice Completes an ownership transfer initiated by TransferOwnership.
 * @dev For tokenPool, poolHooks, and lockBox: calls acceptOwnership() on the entity.
 *      For token: auto-detects the token type and calls the appropriate accept function:
 *        - CrossChainToken (AccessControlDefaultAdminRules): acceptDefaultAdminTransfer()
 *        - OZ Ownable2Step:                                  acceptOwnership()
 *        - ConfirmedOwner / plain Ownable:                   acceptOwnership()
 *          (works for ConfirmedOwner; reverts for plain Ownable since transfer was already immediate)
 *        - BurnMintERC20 v1 (plain AccessControl): transfer was already atomic — no accept step needed.
 *      The signer must be the address that was set as the pending owner/admin.
 *
 * Required env vars:
 *   ENTITY_TYPE — one of: token, tokenPool, poolHooks, lockBox
 *   ADDRESS     — contract address of the entity
 *
 * Usage:
 *   ADDRESS=0xYourPool \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=tokenPool ADDRESS=0xYourPool \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=token ADDRESS=0xYourToken \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=poolHooks ADDRESS=0xYourHooks \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=lockBox ADDRESS=0xYourLockBox \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * If ENTITY_TYPE is omitted, the contract at ADDRESS is treated as a generic IOwnable (same as tokenPool/poolHooks/lockBox).
 */
contract AcceptOwnership is EoaExecutor {
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

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"👑 Accept ", label, " Ownership"));
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       Accept ", _entityActionLabel(entityType), " ownership"));
        console.log("========================================");
        console.log("");

        if (_eq(entityType, "token")) {
            _acceptTokenOwnership(chainId, chainName, entityAddress);
        } else {
            _acceptSimpleOwnership(chainId, chainName, entityType, label, entityAddress);
        }
    }

    function _acceptSimpleOwnership(
        uint256 chainId,
        string memory chainName,
        string memory entityType,
        string memory label,
        address entityAddress
    ) internal {
        IOwnable entity = IOwnable(entityAddress);
        address currentOwner = entity.owner();

        console.log(string.concat("Accept ", label, " Ownership Parameters:"));
        console.log(string.concat("  ", _padRight(string.concat(label, ":"), 14), " ", vm.toString(entityAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));

        address signer = broadcaster();
        console.log(string.concat("  Signer:        ", vm.toString(signer)));
        console.log("");

        console.log(string.concat("\n[Step 1] Accepting ", _entityActionLabel(entityType), " ownership on ", chainName));
        // acceptOwnership reverts on-chain if the signer is not the pending owner
        executeCalls(CctActions.acceptOwnership(entityAddress));
        console.log(unicode"✅ Ownership accepted successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ ", label, " Ownership Accepted on ", chainName, "!"));
        console.log("========================================");
        console.log(
            string.concat(
                _padRight(string.concat(label, ":"), 11),
                " ",
                helperConfig.getExplorerUrl(chainId, "/address/", entityAddress)
            )
        );
        console.log(string.concat("New Owner:  ", vm.toString(signer)));
        console.log("========================================");
        console.log("");
    }

    function _acceptTokenOwnership(uint256 chainId, string memory chainName, address tokenAddress) internal {
        // Auto-detect token type by probing view functions unique to each standard.
        bool isCrossChainToken = false;
        bool isOwnable2Step = false;
        bool isOwnable = false;
        try IAccessControlDefaultAdminRules(tokenAddress).pendingDefaultAdmin() returns (address, uint48) {
            isCrossChainToken = true;
        } catch {}

        if (!isCrossChainToken) {
            try IOwnable(tokenAddress).owner() returns (address) {
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
        }

        if (isCrossChainToken) {
            console.log(
                unicode"ℹ️  Detection: CrossChainToken (AccessControlDefaultAdminRules) — using acceptDefaultAdminTransfer"
            );
        } else if (isOwnable2Step) {
            console.log(unicode"ℹ️  Detection: OZ Ownable2Step — using acceptOwnership");
        } else if (isOwnable) {
            console.log(
                unicode"ℹ️  Detection: Ownable (owner() only, no pendingOwner()) — ConfirmedOwner or plain Ownable"
            );
            console.log(
                unicode"ℹ️  Calling acceptOwnership(). Works for ConfirmedOwner. For plain Ownable: ownership already transferred — this call will revert."
            );
        } else {
            console.log(unicode"ℹ️  Detection: AccessControl (BurnMintERC20 v1) — no accept step required");
            console.log(
                unicode"ℹ️  The DEFAULT_ADMIN_ROLE was transferred atomically by TransferOwnership via grantRole + revokeRole."
            );
            console.log("");
            console.log("========================================");
            console.log(unicode"✅ Nothing to accept — token admin was already transferred.");
            console.log("========================================");
            console.log("");
            return;
        }
        console.log("");

        console.log("Accept Token Ownership Parameters:");
        console.log(string.concat("  Token:         ", vm.toString(tokenAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));

        address signer = broadcaster();
        console.log(string.concat("  Signer:        ", vm.toString(signer)));
        console.log("");

        if (isCrossChainToken) {
            console.log(string.concat("\n[Step 1] Accepting admin transfer (CrossChainToken) on ", chainName));
            // acceptDefaultAdminTransfer reverts if signer is not the pending admin
            executeCalls(CctActions.acceptDefaultAdminTransfer(tokenAddress));
        } else {
            console.log(string.concat("\n[Step 1] Accepting token ownership on ", chainName));
            // acceptOwnership reverts on-chain if the signer is not the pending owner (or if plain Ownable)
            executeCalls(CctActions.acceptOwnership(tokenAddress));
        }
        console.log(unicode"✅ Token ownership accepted successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Token Ownership Accepted on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token:      ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("New Owner:  ", vm.toString(signer)));
        console.log("========================================");
        console.log("");
    }
}
