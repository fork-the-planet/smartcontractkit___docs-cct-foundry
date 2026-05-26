// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";

/// @notice Applies token transfer fee configuration updates to a token pool on a given destination lane.
///
/// @dev This function is only available on TokenPool v2.0 and later. Prior to v2.0, fee configuration
///      is managed by FeeQuoter and configured directly by the Chainlink team upon token issuer request.
///      If the pool does not support this function, the script will revert with an informative message.
///
/// To enable or update the fee config for a lane, provide all required env vars with DISABLE unset or false.
/// To disable the fee config (reverting to FeeQuoter defaults), set DISABLE=true.
///
/// Environment Variables (required):
///   DEST_CHAIN    - The remote destination chain to configure fees for (e.g. MANTLE_SEPOLIA)
///
/// Environment Variables (optional when DISABLE is false or unset — defaults to current on-chain values):
///   DEST_GAS_OVERHEAD             - uint32, gas overhead charged on destination chain (must be > 0)
///   DEST_BYTES_OVERHEAD           - uint32, data availability bytes overhead on destination chain
///   FINALITY_FEE_USD_CENTS        - uint32, fixed fee in 0.01 USD units for finality transfers
///   FAST_FINALITY_FEE_USD_CENTS   - uint32, fixed fee in 0.01 USD units for fast finality transfers
///   FINALITY_TRANSFER_FEE_BPS     - uint16, bps fee deducted from transferred amount for finality transfers [0-9999]
///   FAST_FINALITY_TRANSFER_FEE_BPS - uint16, bps fee deducted from transferred amount for fast finality transfers [0-9999]
///
/// Environment Variables (optional):
///   DISABLE  - true/false, set to true to disable the fee config for this lane (default: false)
///
/// Usage example (enable / update fee config):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   DEST_GAS_OVERHEAD=50000 \
///   DEST_BYTES_OVERHEAD=0 \
///   FINALITY_FEE_USD_CENTS=0 \
///   FAST_FINALITY_FEE_USD_CENTS=100 \
///   FINALITY_TRANSFER_FEE_BPS=0 \
///   FAST_FINALITY_TRANSFER_FEE_BPS=50 \
///   forge script script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
/// Usage example (disable fee config):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   DISABLE=true \
///   forge script script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract UpdateTokenTransferFeeConfig is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");
        bool disable = vm.envOr("DISABLE", false);

        // ── Resolve chain IDs, selectors ────────────────────────────────
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        uint64 destChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;

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

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"💰 Update Token Transfer Fee Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", disable ? "Disable fee config" : "Set fee config"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Dest Chain Selector: ", vm.toString(destChainSelector)));
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(destChainSelector),
            string.concat(
                "Destination chain ",
                helperConfig.getChainName(destChainId),
                " (selector: ",
                vm.toString(destChainSelector),
                ") is not configured on this pool. Run ApplyChainUpdates first."
            )
        );

        if (disable) {
            // ── Disable fee config for this lane ──────────────────────────
            console.log(
                string.concat("[Step 1] Disabling fee config for lane to ", helperConfig.getChainName(destChainId))
            );

            uint64[] memory toDisable = new uint64[](1);
            toDisable[0] = destChainSelector;
            TokenPool.TokenTransferFeeConfigArgs[] memory emptyArgs = new TokenPool.TokenTransferFeeConfigArgs[](0);

            vm.startBroadcast();

            // applyTokenTransferFeeConfigUpdates() was introduced in TokenPool v2.0.
            // On v1 pools, fee configuration is handled by FeeQuoter and requires
            // a direct request to the Chainlink team — it cannot be modified here.
            try tokenPool.applyTokenTransferFeeConfigUpdates(emptyArgs, toDisable) {
                console.log(unicode"✅ Fee config disabled for this lane.");
                console.log("   The OnRamp will now use FeeQuoter defaults for this destination.");
            } catch (bytes memory err) {
                console.log(unicode"❌ Error: applyTokenTransferFeeConfigUpdates() reverted.");
                console.log("   Raw revert data:");
                console.logBytes(err);
                console.log("   If the function selector is missing, the pool may be v1 (requires TokenPool v2.0+).");
                revert("applyTokenTransferFeeConfigUpdates() reverted - see raw error above");
            }

            vm.stopBroadcast();
        } else {
            // ── Read current on-chain config as defaults ───────────────────
            IPoolV2.TokenTransferFeeConfig memory currentConfig;
            try tokenPool.getTokenTransferFeeConfig(address(0), destChainSelector, 0, "") returns (
                IPoolV2.TokenTransferFeeConfig memory cfg
            ) {
                currentConfig = cfg;
                console.log("Current On-Chain Fee Configuration:");
                console.log(
                    string.concat("  isEnabled:                    ", currentConfig.isEnabled ? "true" : "false")
                );
                console.log(
                    string.concat("  destGasOverhead:              ", vm.toString(currentConfig.destGasOverhead))
                );
                console.log(
                    string.concat("  destBytesOverhead:            ", vm.toString(currentConfig.destBytesOverhead))
                );
                console.log(
                    string.concat("  finalityFeeUSDCents:          ", vm.toString(currentConfig.finalityFeeUSDCents))
                );
                console.log(
                    string.concat(
                        "  fastFinalityFeeUSDCents:      ", vm.toString(currentConfig.fastFinalityFeeUSDCents)
                    )
                );
                console.log(
                    string.concat("  finalityTransferFeeBps:       ", vm.toString(currentConfig.finalityTransferFeeBps))
                );
                console.log(
                    string.concat(
                        "  fastFinalityTransferFeeBps:   ", vm.toString(currentConfig.fastFinalityTransferFeeBps)
                    )
                );
                console.log("");
            } catch {
                // Pool is v1 or config not yet set — all defaults will be zero.
            }

            TokenPool.TokenTransferFeeConfigArgs[] memory args = _buildFeeConfigArgs(currentConfig, destChainSelector);
            uint64[] memory emptyDisable = new uint64[](0);

            console.log(
                string.concat("[Step 1] Applying fee config for lane to ", helperConfig.getChainName(destChainId))
            );

            vm.startBroadcast();

            // applyTokenTransferFeeConfigUpdates() was introduced in TokenPool v2.0.
            // On v1 pools, fee configuration is handled by FeeQuoter and requires
            // a direct request to the Chainlink team — it cannot be modified here.
            try tokenPool.applyTokenTransferFeeConfigUpdates(args, emptyDisable) {
                console.log(unicode"✅ Fee config applied successfully!");
            } catch (bytes memory err) {
                console.log(unicode"❌ Error: applyTokenTransferFeeConfigUpdates() reverted.");
                console.log("   Raw revert data:");
                console.logBytes(err);
                console.log("   If the function selector is missing, the pool may be v1 (requires TokenPool v2.0+).");
                revert("applyTokenTransferFeeConfigUpdates() reverted - see raw error above");
            }

            vm.stopBroadcast();
        }

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"✅ Operation Complete!");
        console.log("========================================");
        console.log(string.concat("Token Pool: ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Token Pool: ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress)));
        console.log("========================================");
        console.log("");
    }

    /// @dev Reads fee config env vars (defaulting to current on-chain values), logs the result,
    /// and returns a single-element TokenTransferFeeConfigArgs array ready for broadcast.
    function _buildFeeConfigArgs(IPoolV2.TokenTransferFeeConfig memory currentConfig, uint64 destChainSelector)
        internal
        view
        returns (TokenPool.TokenTransferFeeConfigArgs[] memory args)
    {
        uint32 destGasOverhead = uint32(vm.envOr("DEST_GAS_OVERHEAD", uint256(currentConfig.destGasOverhead)));
        uint32 destBytesOverhead = uint32(vm.envOr("DEST_BYTES_OVERHEAD", uint256(currentConfig.destBytesOverhead)));
        uint32 defaultFeeUSDCents =
            uint32(vm.envOr("FINALITY_FEE_USD_CENTS", uint256(currentConfig.finalityFeeUSDCents)));
        uint32 customFeeUSDCents =
            uint32(vm.envOr("FAST_FINALITY_FEE_USD_CENTS", uint256(currentConfig.fastFinalityFeeUSDCents)));
        uint16 defaultTransferFeeBps =
            uint16(vm.envOr("FINALITY_TRANSFER_FEE_BPS", uint256(currentConfig.finalityTransferFeeBps)));
        uint16 customTransferFeeBps =
            uint16(vm.envOr("FAST_FINALITY_TRANSFER_FEE_BPS", uint256(currentConfig.fastFinalityTransferFeeBps)));

        console.log("Fee Configuration to Apply:");
        console.log(string.concat("  destGasOverhead:              ", vm.toString(destGasOverhead)));
        console.log(string.concat("  destBytesOverhead:            ", vm.toString(destBytesOverhead)));
        console.log(string.concat("  finalityFeeUSDCents:          ", vm.toString(defaultFeeUSDCents)));
        console.log(string.concat("  fastFinalityFeeUSDCents:      ", vm.toString(customFeeUSDCents)));
        console.log(string.concat("  finalityTransferFeeBps:       ", vm.toString(defaultTransferFeeBps)));
        console.log(string.concat("  fastFinalityTransferFeeBps:   ", vm.toString(customTransferFeeBps)));
        console.log("");

        args = new TokenPool.TokenTransferFeeConfigArgs[](1);
        args[0] = TokenPool.TokenTransferFeeConfigArgs({
            destChainSelector: destChainSelector,
            tokenTransferFeeConfig: IPoolV2.TokenTransferFeeConfig({
                destGasOverhead: destGasOverhead,
                destBytesOverhead: destBytesOverhead,
                finalityFeeUSDCents: defaultFeeUSDCents,
                fastFinalityFeeUSDCents: customFeeUSDCents,
                finalityTransferFeeBps: defaultTransferFeeBps,
                fastFinalityTransferFeeBps: customTransferFeeBps,
                isEnabled: true
            })
        });
    }
}
