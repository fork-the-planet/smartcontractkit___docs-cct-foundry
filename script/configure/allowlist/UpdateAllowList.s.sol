// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {HelperUtils} from "../../utils/HelperUtils.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

interface ITokenPoolV1 {
    function applyAllowListUpdates(address[] calldata removes, address[] calldata adds) external;
}

/**
 * @title UpdateAllowList
 * @notice Script to update the allowlist for a TokenPool or AdvancedPoolHooks
 * @dev Calls applyAllowListUpdates(removes, adds) as owner
 *
 * Usage:
 *   TOKEN_POOL=0x... POOL_HOOKS=0x... forge script script/configure/allowlist/UpdateAllowList.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   (If POOL_HOOKS is not set, will try to call on pool contract. If not found, throws error with guidance.)
 */
contract UpdateAllowList is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address tokenPoolAddress = vm.envOr("TOKEN_POOL", helperConfig.getDeployedTokenPool(chainId));
        address hooksAddress = vm.envOr("POOL_HOOKS", address(0));

        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set TOKEN_POOL env var or ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL."
            )
        );

        // Parse allowlist updates — supports CSV ("0xA,0xB") or JSON array ("[\"0xA\",\"0xB\"]")
        address[] memory removes = HelperUtils.parseAddressArray(vm, vm.envOr("REMOVE_ADDRESSES", string("")), "");
        address[] memory adds = HelperUtils.parseAddressArray(vm, vm.envOr("ADD_ADDRESSES", string("")), "");

        console.log("");
        console.log("========================================");
        console.log(unicode"📝 Update AllowList");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        if (hooksAddress != address(0)) {
            console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        }
        console.log(string.concat("Action:       ", "Update allowlist"));
        console.log("========================================");
        console.log("");

        vm.startBroadcast();
        bool success = false;
        string memory errorMsg = "";
        if (hooksAddress != address(0)) {
            // Try to call on AdvancedPoolHooks
            try AdvancedPoolHooks(hooksAddress).applyAllowListUpdates(removes, adds) {
                success = true;
            } catch (bytes memory err) {
                console.log(unicode"❌ Error: applyAllowListUpdates() reverted on AdvancedPoolHooks.");
                console.log("   Raw revert data:");
                console.logBytes(err);
                console.log(
                    "   If the error is OnlyCallableByOwner(), ensure you are broadcasting with the hooks owner's account."
                );
                errorMsg = unicode"❌ Error: applyAllowListUpdates() reverted - see raw error above.";
            }
        } else {
            // Try to call on TokenPool (v1) via interface
            try ITokenPoolV1(tokenPoolAddress).applyAllowListUpdates(removes, adds) {
                success = true;
            } catch (bytes memory err) {
                console.log(unicode"❌ Error: applyAllowListUpdates() reverted on TokenPool.");
                console.log("   Raw revert data:");
                console.logBytes(err);
                console.log(
                    "   If the function selector is not found, you may be using TokenPool v2.0+ which requires AdvancedPoolHooks."
                );
                console.log(
                    "   Deploy AdvancedPoolHooks using DeployAdvancedPoolHooks.s.sol, connect it via UpdateAdvancedPoolHooks.s.sol, then pass its address as POOL_HOOKS."
                );
                errorMsg = unicode"❌ Error: applyAllowListUpdates() reverted - see raw error above.";
            }
        }
        vm.stopBroadcast();

        if (success) {
            console.log(unicode"✅ AllowList updated successfully!");
        } else {
            console.log(errorMsg);
            revert(errorMsg);
        }
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Allowlist updated on ", chainName, "!"));
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        if (hooksAddress != address(0)) {
            console.log(
                string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress))
            );
        }
        console.log("========================================");
        console.log("");
    }
}
