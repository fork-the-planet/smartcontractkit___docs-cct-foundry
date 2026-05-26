// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/interfaces/IAdvancedPoolHooks.sol";

/// @notice Reads and displays the AdvancedPoolHooks contract address currently attached to a token pool.
///
/// Usage example:
///   forge script script/configure/allowlist/GetAdvancedPoolHooks.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetAdvancedPoolHooks is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"🪝 Get Advanced Pool Hooks");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View pool hooks"));
        console.log("========================================");
        console.log("");

        // ── Query hooks ────────────────────────────────────────────────────
        // getAdvancedPoolHooks() is only available on TokenPool v2.0 and later.
        try TokenPool(tokenPoolAddress).getAdvancedPoolHooks() returns (IAdvancedPoolHooks hooks) {
            if (address(hooks) == address(0)) {
                console.log("No AdvancedPoolHooks contract is attached to this pool.");
                console.log(
                    "   Deploy one with DeployAdvancedPoolHooks.s.sol and attach it via UpdateAdvancedPoolHooks.s.sol."
                );
            } else {
                console.log(unicode"✅ AdvancedPoolHooks:");
                console.log(string.concat("   ", vm.toString(address(hooks))));
            }
        } catch (bytes memory err) {
            console.log(unicode"❌ Error: getAdvancedPoolHooks() reverted.");
            console.log("   Raw revert data:");
            console.logBytes(err);
            console.log("   If the function selector is missing, the pool may be v1 (requires TokenPool v2.0+).");
            revert("getAdvancedPoolHooks() reverted - see raw error above");
        }

        console.log("");
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
