// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {HelperUtils} from "../../utils/HelperUtils.s.sol";
import {DeploymentUtils} from "../../utils/DeploymentUtils.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

/**
 * @title DeployAdvancedPoolHooks
 * @notice Optional script to deploy AdvancedPoolHooks for enhanced token pool security
 * @dev AdvancedPoolHooks provides:
 *      - Allowlist functionality for sender restrictions
 *      - CCV (Cross-Chain Validation) configuration management
 *      - Policy engine integration for custom validation logic
 *      - Threshold-based additional security for large transfers
 *
 * Configuration is read from script/input/advanced-pool-hooks.json, which can be overridden per-field
 * using environment variables.
 *
 * Usage:
 *   forge script script/configure/allowlist/DeployAdvancedPoolHooks.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variable overrides (all optional, fall back to script/input/advanced-pool-hooks.json):
 *   ALLOWLIST           — CSV or JSON array of allowed addresses  (e.g. "0xA,0xB" or '["0xA","0xB"]')
 *   AUTHORIZED_CALLERS  — CSV or JSON array of authorized pool addresses
 *   THRESHOLD_AMOUNT    — uint256 threshold amount
 *   POLICY_ENGINE       — address of the policy engine contract
 *
 * Edit script/input/advanced-pool-hooks.json to configure defaults:
 *   - allowlist: Array of addresses allowed to transfer tokens
 *   - thresholdAmount: Amount above which additional CCVs are required
 *   - policyEngine: Address of policy engine contract (or 0x0 to disable)
 *   - authorizedCallers: Array of token pool addresses authorized to use these hooks
 */
contract DeployAdvancedPoolHooks is Script {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        string memory chainNameId = helperConfig.getNetworkConfig(chainId).chainNameIdentifier;

        console.log("");
        console.log("========================================");
        console.log(unicode"🔒 Deploy Advanced Pool Hooks");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Deploy pool hooks"));
        console.log("========================================");
        console.log("");

        // Define the path to the configuration file
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, "/script/input/advanced-pool-hooks.json");

        // Parse parameters — env vars take priority, JSON config is the fallback
        string memory allowlistEnv = vm.envOr("ALLOWLIST", string(""));
        address[] memory allowlist = bytes(allowlistEnv).length > 0
            ? HelperUtils.parseAddressArray(vm, allowlistEnv, "")
            : HelperUtils.parseAddressArray(vm, configPath, ".allowlist");

        uint256 thresholdAmount =
            vm.envOr("THRESHOLD_AMOUNT", HelperUtils.getUintFromJson(vm, configPath, ".thresholdAmount"));
        address policyEngine =
            vm.envOr("POLICY_ENGINE", HelperUtils.getAddressFromJson(vm, configPath, ".policyEngine"));

        string memory callersEnv = vm.envOr("AUTHORIZED_CALLERS", string(""));
        address[] memory authorizedCallers = bytes(callersEnv).length > 0
            ? HelperUtils.parseAddressArray(vm, callersEnv, "")
            : HelperUtils.parseAddressArray(vm, configPath, ".authorizedCallers");

        console.log("Advanced Pool Hooks Parameters:");
        console.log(string.concat("  Allowlist Enabled:            ", allowlist.length > 0 ? "Yes" : "No"));
        if (allowlist.length > 0) {
            console.log(string.concat("  Allowlist Size:               ", vm.toString(allowlist.length)));
            for (uint256 i = 0; i < allowlist.length; i++) {
                console.log(string.concat("    [", vm.toString(i), "] ", vm.toString(allowlist[i])));
            }
        }
        console.log(
            string.concat(
                "  Threshold Amount:             ", thresholdAmount > 0 ? vm.toString(thresholdAmount) : "Disabled (0)"
            )
        );
        console.log(
            string.concat(
                "  Policy Engine:                ",
                policyEngine != address(0) ? vm.toString(policyEngine) : "Disabled (0x0)"
            )
        );
        console.log(string.concat("  Authorized Callers Enabled:   ", authorizedCallers.length > 0 ? "Yes" : "No"));
        if (authorizedCallers.length > 0) {
            console.log(string.concat("  Authorized Callers Size:      ", vm.toString(authorizedCallers.length)));
            for (uint256 i = 0; i < authorizedCallers.length; i++) {
                console.log(string.concat("    [", vm.toString(i), "] ", vm.toString(authorizedCallers[i])));
            }
        }
        console.log("");

        vm.startBroadcast();

        console.log(string.concat("\n[Step 1] Deploying AdvancedPoolHooks on ", chainName));
        AdvancedPoolHooks hooks = new AdvancedPoolHooks(allowlist, thresholdAmount, policyEngine, authorizedCallers);
        address hooksAddress = address(hooks);
        console.log(string.concat("AdvancedPoolHooks deployed at: ", vm.toString(hooksAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress));
        console.log(unicode"✅ AdvancedPoolHooks deployed successfully!");

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deployment Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("AdvancedPoolHooks Address: ", vm.toString(hooksAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress));
        console.log("");
        DeploymentUtils.savePoolHooksDeployment(vm, chainNameId, hooksAddress);
        console.log("");
        console.log("Configuration Summary:");
        console.log(string.concat("  Allowlist:                    ", allowlist.length > 0 ? "Enabled" : "Disabled"));
        console.log(
            string.concat(
                "  Threshold:                    ", thresholdAmount > 0 ? vm.toString(thresholdAmount) : "Disabled"
            )
        );
        console.log(
            string.concat(
                "  Policy Engine:                ", policyEngine != address(0) ? vm.toString(policyEngine) : "Disabled"
            )
        );
        console.log(
            string.concat("  Authorized Callers:           ", authorizedCallers.length > 0 ? "Enabled" : "Disabled")
        );
        console.log("");
        console.log("Next Steps:");
        console.log("  1. When deploying a TokenPool, pass this hooks address as the 'poolHooks' parameter");
        console.log(
            "  2. Attach to an existing pool: TOKEN_POOL=<address> NEW_HOOK=<address> forge script script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol --rpc-url $RPC_URL --account $KEYSTORE_NAME --broadcast"
        );
        console.log(
            "  3. Manage allowlist: POOL_HOOKS=<address> ADD_ADDRESSES=\"0xAddr\" forge script script/configure/allowlist/UpdateAllowList.s.sol --rpc-url $RPC_URL --account $KEYSTORE_NAME --broadcast"
        );
        console.log("========================================");
        console.log("");
    }
}
