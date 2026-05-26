// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";

/// @notice Adds a remote pool address to a TokenPool for a given remote chain.
///
/// @dev Use this when a pool has been upgraded on a remote chain. The old pool address is kept
///      to allow inflight messages to complete. Multiple remote pool addresses can be active
///      at the same time for the same chain selector.
/// @dev The remote chain must already be supported (added via ApplyChainUpdates) before calling this.
///
/// Environment Variables (required):
///   DEST_CHAIN         - The remote chain where the new pool was deployed (e.g. MANTLE_SEPOLIA)
///   REMOTE_POOL_ADDRESS - The address of the new remote pool to add
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   REMOTE_POOL_ADDRESS=0xNewRemotePoolAddress \
///   forge script script/configure/remote-pools/AddRemotePool.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract AddRemotePool is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");
        address remotePoolAddress = vm.envAddress("REMOTE_POOL_ADDRESS");

        // ── Resolve chain IDs and selectors ───────────────────────────────
        helperConfig = new HelperConfig();
        uint256 sourceChainId = block.chainid;
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        string memory sourceChainName = helperConfig.getChainName(sourceChainId);
        uint64 remoteChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(remoteChainSelector),
            string.concat(
                "Remote chain not supported. Run ApplyChainUpdates first to add ",
                destChainName,
                " as a supported chain."
            )
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"➕ Add Remote Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Add remote pool"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("New Remote Pool: ", vm.toString(remotePoolAddress)));
        console.log("");

        // ── Show current remote pools ──────────────────────────────────────
        bytes[] memory currentPools = tokenPool.getRemotePools(remoteChainSelector);
        console.log(string.concat("Current Remote Pools: ", vm.toString(currentPools.length)));
        for (uint256 i = 0; i < currentPools.length; i++) {
            if (currentPools[i].length == 32) {
                console.log(
                    string.concat("  [", vm.toString(i), "] ", vm.toString(abi.decode(currentPools[i], (address))))
                );
            } else {
                console.log(string.concat("  [", vm.toString(i), "] (raw) ", vm.toString(currentPools[i])));
            }
        }
        console.log("");

        vm.startBroadcast();

        console.log(string.concat("[Step 1] Adding remote pool on ", sourceChainName));

        tokenPool.addRemotePool(remoteChainSelector, abi.encode(remotePoolAddress));

        vm.stopBroadcast();

        console.log(unicode"✅ Remote pool added successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Complete on ", sourceChainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Remote Chain:    ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Added Pool:      ", vm.toString(remotePoolAddress)));
        console.log(
            string.concat(
                "Token Pool:      ", helperConfig.getExplorerUrl(sourceChainId, "/address/", tokenPoolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }
}
