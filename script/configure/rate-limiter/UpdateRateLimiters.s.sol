// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {RateLimiterUtils, ITokenPoolV1RateLimiter} from "../../utils/RateLimiterUtils.s.sol";

/// @notice Updates rate limiter configuration on a TokenPool, compatible with both v1 and v2 pools.
///
/// The direction(s) to update are inferred automatically: set OUTBOUND_* vars to update outbound,
/// INBOUND_* vars to update inbound, or both sets to update both. At least one direction must be provided.
///
/// Environment Variables (required):
///   DEST_CHAIN                    - The remote chain whose rate limit lane is being updated (e.g. MANTLE_SEPOLIA)
///
/// Environment Variables (set to update outbound — any one triggers the direction):
///   OUTBOUND_RATE_LIMIT_CAPACITY  - uint128, token bucket capacity (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_RATE      - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_ENABLED   - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///
/// Environment Variables (set to update inbound — any one triggers the direction):
///   INBOUND_RATE_LIMIT_CAPACITY   - uint128, token bucket capacity (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_RATE       - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_ENABLED    - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///
/// Environment Variables (optional, v2 only):
///   FAST_FINALITY                  - true/false, whether to update the fast finality rate limit
///                                   bucket (default: false, uses the standard finality bucket)
///
/// Usage examples:
///   # Enable both directions (isEnabled inferred from CAPACITY/RATE being set):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
///   OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
///   INBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   forge script script/configure/rate-limiter/UpdateRateLimiters.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Disable outbound only:
///   DEST_CHAIN=MANTLE_SEPOLIA OUTBOUND_RATE_LIMIT_ENABLED=false \
///   forge script script/configure/rate-limiter/UpdateRateLimiters.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract UpdateRateLimiters is Script {
    // ── Storage: shared between run() and helper functions ─────────────────
    // Using storage instead of function parameters eliminates EVM stack pressure.
    HelperConfig public helperConfig;
    address private s_poolAddress;
    uint64 private s_selector;
    bool private s_fastFinality;
    bool private s_isV2;
    uint256 private s_chainId;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");
        s_fastFinality = vm.envOr("FAST_FINALITY", false);

        // ── Infer direction from which env vars are present ────────────────
        // Sentinel pattern: any OUTBOUND_* or INBOUND_* var triggers that direction.
        // isEnabled defaults to true when CAPACITY or RATE are provided.
        RateLimiterUtils.RateLimitUpdate memory update = RateLimiterUtils.readRateLimitUpdate();
        require(
            update.updateOutbound || update.updateInbound,
            "At least one direction must be specified: set OUTBOUND_* and/or INBOUND_* rate limit env vars"
        );

        // ── Resolve chain IDs / selectors, store in contract storage ───────
        helperConfig = new HelperConfig();
        s_chainId = block.chainid;
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        s_selector = helperConfig.getNetworkConfig(destChainId).chainSelector;

        // ── Resolve pool, detect version ───────────────────────────────────
        s_poolAddress = helperConfig.getDeployedTokenPool(s_chainId);
        require(
            s_poolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(s_chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );
        s_isV2 = RateLimiterUtils.isV2Pool(TokenPool(s_poolAddress), s_selector, s_fastFinality);

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"⚡️ Update Rate Limiters");
        console.log("========================================");
        console.log(string.concat("Chain:        ", helperConfig.getChainName(s_chainId)));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(s_poolAddress)));
        console.log(string.concat("Action:       ", "Update rate limits"));
        console.log(
            string.concat(
                "Direction:    ", RateLimiterUtils.directionLabel(update.updateOutbound, update.updateInbound)
            )
        );
        console.log(s_fastFinality ? "Bucket:       Fast finality" : "Bucket:       Standard finality");
        console.log("========================================");
        console.log("");

        console.log(
            string.concat("Pool Version: ", s_isV2 ? "v2 (setRateLimitConfig)" : "v1 (setChainRateLimiterConfig)")
        );
        console.log("");

        RateLimiterUtils.logRateLimiterState(
            TokenPool(s_poolAddress), ITokenPoolV1RateLimiter(s_poolAddress), s_selector, s_fastFinality, s_isV2
        );

        // ── Build configs from on-chain state + update, then broadcast ─────
        _applyRateLimitUpdate(update);

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(
            string.concat(unicode"✅ Rate limiter update complete on ", helperConfig.getChainName(s_chainId), "!")
        );
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(s_poolAddress)));
        console.log(string.concat("Token Pool:   ", helperConfig.getExplorerUrl(s_chainId, "/address/", s_poolAddress)));
        console.log("========================================");
        console.log("");
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Merges on-chain state with user input, logs the result, and broadcasts.
    function _applyRateLimitUpdate(RateLimiterUtils.RateLimitUpdate memory u) internal {
        // Seed from live state so untouched directions keep their current values.
        (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) = RateLimiterUtils.getCurrentConfigs(
            TokenPool(s_poolAddress), ITokenPoolV1RateLimiter(s_poolAddress), s_selector, s_fastFinality, s_isV2
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
        _broadcastRateLimitConfig(outbound, inbound);
    }

    /// @dev Broadcasts the on-chain call (v1 or v2 pool).
    function _broadcastRateLimitConfig(RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) internal {
        vm.startBroadcast();
        if (s_isV2) {
            TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
            args[0] = TokenPool.RateLimitConfigArgs({
                remoteChainSelector: s_selector,
                fastFinality: s_fastFinality,
                outboundRateLimiterConfig: outbound,
                inboundRateLimiterConfig: inbound
            });
            TokenPool(s_poolAddress).setRateLimitConfig(args);
        } else {
            if (s_fastFinality) {
                console.log(
                    unicode"⚠️  Warning: FAST_FINALITY=true is ignored on v1 pools. Updating the standard bucket."
                );
            }
            ITokenPoolV1RateLimiter(s_poolAddress).setChainRateLimiterConfig(s_selector, outbound, inbound);
        }
        vm.stopBroadcast();
    }
}
