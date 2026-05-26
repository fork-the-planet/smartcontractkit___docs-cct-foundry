// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";

/**
 * @title GetAuthorizedCallers
 * @notice Script to fetch and print the authorized callers from an AdvancedPoolHooks or ERC20LockBox contract
 *
 * Usage:
 *   POOL_HOOKS=0x... forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME
 *   LOCK_BOX=0x...   forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME
 *
 * Environment variables:
 *   POOL_HOOKS -- address of an AdvancedPoolHooks contract  (one of POOL_HOOKS or LOCK_BOX required)
 *   LOCK_BOX   -- address of an ERC20LockBox contract       (one of POOL_HOOKS or LOCK_BOX required)
 */
contract GetAuthorizedCallers is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address poolHooks = vm.envOr("POOL_HOOKS", address(0));
        address lockBox = vm.envOr("LOCK_BOX", address(0));
        require(poolHooks != address(0) || lockBox != address(0), "POOL_HOOKS or LOCK_BOX env var required");
        require(poolHooks == address(0) || lockBox == address(0), "Only one of POOL_HOOKS or LOCK_BOX may be set");

        bool isLockBox = lockBox != address(0);
        address contractAddress = isLockBox ? lockBox : poolHooks;
        string memory labelHeader = isLockBox ? "LockBox:      " : "Pool Hooks:   ";

        console.log("");
        console.log("========================================");
        console.log(unicode"🔎 Get Authorized Callers");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat(labelHeader, vm.toString(contractAddress)));
        console.log(string.concat("Action:       ", "View authorized callers"));
        console.log("========================================");
        console.log("");

        address[] memory callers = AuthorizedCallers(contractAddress).getAllAuthorizedCallers();
        console.log(string.concat("Authorized Callers count: ", vm.toString(callers.length)));
        for (uint256 i = 0; i < callers.length; i++) {
            console.log(string.concat("  [", vm.toString(i), "] ", vm.toString(callers[i])));
        }
        console.log("========================================");
        console.log(string.concat(labelHeader, helperConfig.getExplorerUrl(chainId, "/address/", contractAddress)));
        console.log("========================================");
        console.log("");
    }
}
