// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {RateLimiterUtils, ITokenPoolV1RateLimiter} from "../../utils/RateLimiterUtils.s.sol";
import {FinalityConfigUtils} from "../../utils/FinalityConfigUtils.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Sets the allowed finality configuration on a TokenPool, and optionally updates rate limits
/// for the fast finality bucket on a specific remote chain lane.
///
/// @dev This function is only available on TokenPool v2.0 and later.
/// The allowed finality config controls which fast finality modes are accepted for cross-chain transfers.
///
/// Exactly one finality mode must be specified (or none, to use WAIT_FOR_FINALITY as the default):
///   BLOCK_DEPTH=<n>                      — Allow fast finality after N block confirmations (1–65535).
///   WAIT_FOR_SAFE=true                   — Allow fast finality transfers using the `safe` head.
///   BLOCK_DEPTH=<n> + WAIT_FOR_SAFE=true — Allow both modes simultaneously (pool accepts either).
///   (neither)                            — WAIT_FOR_FINALITY (default): disables fast finality transfers.
///
/// Environment Variables (finality mode — any combination):
///   BLOCK_DEPTH    - uint16, number of block confirmations to allow (1–65535).
///   WAIT_FOR_SAFE  - true/false, set to true to also allow transfers using the `safe` head.
///
/// Environment Variables (optional — rate limiter):
///   DEST_CHAIN                    - Remote chain whose lane is queried/updated (e.g. MANTLE_SEPOLIA).
///                                   Required when any rate limit variable is set; if omitted the rate
///                                   limiter section is skipped entirely.
///   OUTBOUND_RATE_LIMIT_CAPACITY  - uint128, outbound token bucket capacity
///   OUTBOUND_RATE_LIMIT_RATE      - uint128, outbound token bucket refill rate
///   OUTBOUND_RATE_LIMIT_ENABLED   - true/false (defaults to true when CAPACITY or RATE are set)
///   INBOUND_RATE_LIMIT_CAPACITY   - uint128, inbound token bucket capacity
///   INBOUND_RATE_LIMIT_RATE       - uint128, inbound token bucket refill rate
///   INBOUND_RATE_LIMIT_ENABLED    - true/false (defaults to true when CAPACITY or RATE are set)
///
/// Behaviour (rate limiter section):
///   * DEST_CHAIN only               -> logs current rate limits for the fast finality bucket
///   * DEST_CHAIN + rate limit vars  -> logs current, applies updates, logs updated state
///   * Rate limit vars without DEST_CHAIN -> reverts with a helpful error
///
/// Usage examples:
///   # Set block depth and configure the fast finality rate limit bucket:
///   BLOCK_DEPTH=5 DEST_CHAIN=MANTLE_SEPOLIA \
///   OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Set block depth only (no rate limit changes):
///   BLOCK_DEPTH=5 \
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Use WAIT_FOR_SAFE mode and view current rate limits for a lane (no update):
///   WAIT_FOR_SAFE=true DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Reset to default finality (disables fast finality transfers):
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract SetFinalityConfig is EoaExecutor {
    HelperConfig public helperConfig;

    // ── Storage: avoids EVM stack pressure inside run() ────────────────────
    bytes4 private s_newFinalityConfig;

    function run() external {
        // ── Build and validate finality config ────────────────────────────
        s_newFinalityConfig = _buildFinalityConfig();

        // ── Optional env vars — rate limiter ───────────────────────────────
        string memory sentinel = "__not_set__";
        bool destChainSet = keccak256(bytes(vm.envOr("DEST_CHAIN", sentinel))) != keccak256(bytes(sentinel));
        string memory destChainName = destChainSet ? vm.envString("DEST_CHAIN") : "";

        RateLimiterUtils.RateLimitUpdate memory update = RateLimiterUtils.readRateLimitUpdate();
        bool hasRateLimitUpdate = update.updateOutbound || update.updateInbound;

        require(
            !hasRateLimitUpdate || destChainSet,
            "DEST_CHAIN must be set when specifying rate limit environment variables"
        );

        // ── Resolve chain ID ──────────────────────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // ── Resolve remote chain (only when DEST_CHAIN is set) ─────────────
        uint64 remoteChainSelector;
        string memory destChainFullName;
        bool isV2;
        if (destChainSet) {
            uint256 destChainId = helperConfig.parseChainName(destChainName);
            remoteChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;
            destChainFullName = helperConfig.getChainName(destChainId);
            isV2 = RateLimiterUtils.isV2Pool(tokenPool, remoteChainSelector, true);
        }

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"⏱️  Set Finality Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        if (destChainSet) {
            console.log(string.concat("Remote Chain: ", destChainFullName));
        }
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Set finality config"));
        console.log("========================================");
        console.log("");

        // ── Show current and new finality config ───────────────────────────
        _logCurrentConfig(tokenPool);
        console.log(
            string.concat("  New Finality Config:          ", vm.toString(abi.encodePacked(s_newFinalityConfig)))
        );
        console.log(
            string.concat("  Mode:                         ", FinalityConfigUtils.decodeModeLabel(s_newFinalityConfig))
        );
        console.log("");

        // ── Log current rate limits (if DEST_CHAIN provided) ──────────────
        if (destChainSet) {
            console.log("----------------------------------------");
            console.log(unicode"📊 Current Rate Limits (fast finality where enabled, standard otherwise):");
            console.log("----------------------------------------");
            RateLimiterUtils.logRateLimiterStateWithFallback(
                tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, isV2
            );
        }

        // ── Step 1: Set finality config ────────────────────────────────────
        console.log(string.concat("[Step 1] Setting finality config on ", chainName));

        executeCalls(CctActions.setAllowedFinalityConfig(tokenPoolAddress, s_newFinalityConfig));
        console.log(unicode"✅ Finality config set successfully!");

        // ── Step 2: Apply rate limit update (if requested) ─────────────────
        if (hasRateLimitUpdate) {
            _applyRateLimitUpdate(
                tokenPool, tokenPoolAddress, remoteChainSelector, destChainFullName, chainName, update, isV2
            );
        }

        // ── Log updated rate limits (if DEST_CHAIN provided) ──────────────
        if (destChainSet) {
            console.log("");
            console.log("----------------------------------------");
            console.log(unicode"📊 Updated Rate Limits (fast finality where enabled, standard otherwise):");
            console.log("----------------------------------------");
            RateLimiterUtils.logRateLimiterStateWithFallback(
                tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, isV2
            );
        }

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Configuration Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Finality Config: ", vm.toString(abi.encodePacked(s_newFinalityConfig))));
        console.log(string.concat("Mode:            ", FinalityConfigUtils.decodeModeLabel(s_newFinalityConfig)));
        console.log(
            string.concat("Token Pool:      ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Reads BLOCK_DEPTH / WAIT_FOR_SAFE env vars, validates them, and encodes the bytes4 config.
    /// Extracted into its own function to keep the EVM stack depth of run() within the 16-slot limit.
    function _buildFinalityConfig() internal view returns (bytes4) {
        bool waitForSafe = vm.envOr("WAIT_FOR_SAFE", false);
        uint256 blockDepthRaw = vm.envOr("BLOCK_DEPTH", uint256(0));

        require(blockDepthRaw <= FinalityCodec.MAX_BLOCK_DEPTH, "BLOCK_DEPTH must be <= FinalityCodec.MAX_BLOCK_DEPTH");

        if (waitForSafe && blockDepthRaw > 0) return FinalityCodec._encodeBlockDepthAndSafeFlag(uint16(blockDepthRaw));
        if (waitForSafe) return FinalityCodec.WAIT_FOR_SAFE_FLAG;
        if (blockDepthRaw > 0) return FinalityCodec._encodeBlockDepth(uint16(blockDepthRaw));
        return FinalityCodec.WAIT_FOR_FINALITY_FLAG;
    }

    /// @dev Logs the current on-chain finality config. Isolated to avoid stack depth pressure in run().
    function _logCurrentConfig(TokenPool tokenPool) internal view {
        try tokenPool.getAllowedFinalityConfig() returns (bytes4 currentFinality) {
            console.log(
                string.concat("  Current Finality Config:      ", vm.toString(abi.encodePacked(currentFinality)))
            );
        } catch {
            console.log(string.concat("  Current Finality Config:      ", "Not available (pool version < 2.0)"));
        }
    }

    /// @dev Applies a rate limit update to the fast finality bucket. Isolated to reduce run() stack depth.
    function _applyRateLimitUpdate(
        TokenPool tokenPool,
        address tokenPoolAddress,
        uint64 remoteChainSelector,
        string memory destChainFullName,
        string memory chainName,
        RateLimiterUtils.RateLimitUpdate memory u,
        bool isV2
    ) internal {
        console.log("");
        console.log(
            string.concat(
                "[Step 2] Updating rate limits (fast finality bucket) on ", chainName, " -> ", destChainFullName
            )
        );

        (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) = RateLimiterUtils.getCurrentConfigs(
            tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, true, isV2
        );

        if (u.updateOutbound) {
            outbound = RateLimiter.Config({
                isEnabled: u.outboundEnabled,
                capacity: u.outboundEnabled ? u.outboundCapacity : 0,
                rate: u.outboundEnabled ? u.outboundRate : 0
            });
        }
        if (u.updateInbound) {
            inbound = RateLimiter.Config({
                isEnabled: u.inboundEnabled,
                capacity: u.inboundEnabled ? u.inboundCapacity : 0,
                rate: u.inboundEnabled ? u.inboundRate : 0
            });
        }

        RateLimiterUtils.logNewConfig(u.updateOutbound, outbound, u.updateInbound, inbound);

        // Fast-finality bucket update (fastFinality=true) through the version-detected action dispatch.
        // setAllowedFinalityConfig above already established this is a v2 pool.
        executeCalls(CctActions.setRateLimits(address(tokenPool), isV2, remoteChainSelector, true, outbound, inbound));

        console.log(unicode"✅ Rate limits updated successfully!");
    }
}
