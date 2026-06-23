// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";

/// @notice Reads and displays TokenAdminRegistry.getTokenConfig(tokenAddress) for a token.
///
/// Required env vars (one of):
///   - Inline alias: TOKEN=0x...
///   - Chain-specific: {CHAIN}_TOKEN (e.g. ETHEREUM_SEPOLIA_TOKEN=0x...)
///
/// Usage example:
///   TOKEN=0xYourToken forge script script/setup/GetTokenConfig.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetTokenConfig is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not set. Set TOKEN or ",
                config.chainNameIdentifier,
                "_TOKEN environment variable. Example: TOKEN=0x... forge script ..."
            )
        );

        require(config.tokenAdminRegistry != address(0), "TokenAdminRegistry not defined for this network");
        TokenAdminRegistry tokenAdminRegistryContract = TokenAdminRegistry(config.tokenAdminRegistry);

        console.log("");
        console.log("========================================");
        console.log(unicode"📋 Get Token Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token:        ", vm.toString(tokenAddress)));
        console.log(string.concat("Registry:     ", vm.toString(config.tokenAdminRegistry)));
        console.log(string.concat("Action:       ", "Read getTokenConfig"));
        console.log("========================================");
        console.log("");

        TokenAdminRegistry.TokenConfig memory tokenConfig = tokenAdminRegistryContract.getTokenConfig(tokenAddress);

        console.log("Token Config:");
        console.log(string.concat("  administrator:        ", vm.toString(tokenConfig.administrator)));
        console.log(string.concat("  pendingAdministrator: ", vm.toString(tokenConfig.pendingAdministrator)));
        console.log(string.concat("  tokenPool:            ", vm.toString(tokenConfig.tokenPool)));

        console.log("");
        console.log("========================================");
        console.log(string.concat("Token:        ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        if (tokenConfig.tokenPool != address(0)) {
            console.log(string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenConfig.tokenPool)));
        }
        console.log(
            string.concat("Registry:     ", helperConfig.getExplorerUrl(chainId, "/address/", config.tokenAdminRegistry))
        );
        console.log("========================================");
        console.log("");
    }
}

