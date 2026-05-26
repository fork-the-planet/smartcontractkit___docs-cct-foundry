// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {ChainHandlers} from "../utils/ChainHandlers.s.sol";

/// @notice Configures cross-chain lanes on the source TokenPool by calling applyChainUpdates.
/// Sets the remote pool(s), remote token, and optional rate limiter configs per destination chain.
/// Idempotent: if a destination chain is already configured, the existing config is removed and replaced.
///
/// Supports two input modes, chosen by whether VIA_JSON_FILE is set:
///
/// ─── JSON FILE MODE ────────────────────────────────────────────────────────
/// VIA_JSON_FILE=true  Reads config from script/input/apply-chain-updates.json.
///
/// The JSON file allows configuring multiple destination chains and multiple remote pool addresses
/// per chain in a single transaction — something that is impractical via inline CLI args.
///
/// JSON schema:
///   {
///     "sourcePool": "0x...",          // optional — overrides TOKEN_POOL / <CHAIN>_TOKEN_POOL env var
///     "remoteChains": [
///       {
///         "destChain": "MANTLE_SEPOLIA",         // required — chain name identifier
///         "destChainFamily": "evm",              // optional — auto-detected; set "svm" for Solana
///         "destChainSelector": 0,                // optional — auto-detected from destChain
///         "destPools": ["0x...", "0x..."],        // required — one or more remote pool addresses
///         "destToken": "0x...",                  // required — remote token address
///         "outboundRateLimit": {                 // optional — defaults to disabled
///           "enabled": false,
///           "capacity": 0,
///           "rate": 0
///         },
///         "inboundRateLimit": {                  // optional — defaults to disabled
///           "enabled": false,
///           "capacity": 0,
///           "rate": 0
///         }
///       }
///     ]
///   }
///
/// See script/input/apply-chain-updates.json for a working example.
///
/// ─── CLI / ENV VAR MODE (single destination chain) ─────────────────────────
/// Environment Variables (required):
///   DEST_CHAIN                    - The destination chain name (e.g. MANTLE_SEPOLIA)
///   <SOURCE_CHAIN>_TOKEN_POOL     - Address of the token pool on the source chain
///                                   (or use the chain-agnostic alias: TOKEN_POOL=0x...)
///
/// Environment Variables (EVM destinations — at least one form required):
///   DEST_TOKEN_POOL               - EVM address of the token pool on the destination chain
///                                   (overrides the chain-specific <DEST_CHAIN>_TOKEN_POOL var)
///   <DEST_CHAIN>_TOKEN_POOL       - EVM address of the token pool on the destination chain
///   DEST_TOKEN                    - EVM address of the token on the destination chain
///                                   (overrides the chain-specific <DEST_CHAIN>_TOKEN var)
///   <DEST_CHAIN>_TOKEN            - EVM address of the token on the destination chain
///
/// Environment Variables (non-EVM destinations):
///   DEST_CHAIN_FAMILY             - "svm"/"solana" (default: "evm")
///                                   (auto-detected for SOLANA_DEVNET)
///   DEST_CHAIN_SELECTOR           - uint64 chain selector for the destination chain
///                                   (auto-detected for SOLANA_DEVNET)
///   DEST_TOKEN_POOL               - Destination pool address in its native format
///                                   (base58 for SVM)
///   DEST_TOKEN                    - Destination token address in its native format
///
/// Environment Variables (optional — rate limiting disabled by default):
///   OUTBOUND_RATE_LIMIT_CAPACITY  - uint128, token bucket capacity (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_RATE      - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_ENABLED   - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///   INBOUND_RATE_LIMIT_CAPACITY   - uint128, token bucket capacity (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_RATE       - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_ENABLED    - true/false (optional override; defaults to true if CAPACITY/RATE provided)
contract ApplyChainUpdates is Script {
    HelperConfig public helperConfig;

    /// @dev Bundles resolved destination chain parameters into a single struct to
    ///      avoid exceeding the EVM's 16-slot stack limit inside run().
    struct DestChainParams {
        uint64 chainSelector;
        string displayName;
        /// @dev Only used in CLI mode (single-pool). In JSON mode rawPoolAddresses is used instead.
        string rawPoolAddress;
        string rawTokenAddress;
        /// @dev Only used in CLI mode (single-pool).
        bytes poolEncoded;
        bytes tokenEncoded;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Entry point
    // ─────────────────────────────────────────────────────────────────────────

    string internal constant JSON_INPUT_FILE = "script/input/apply-chain-updates.json";

    function run() external {
        helperConfig = new HelperConfig();

        if (vm.envOr("VIA_JSON_FILE", false)) {
            _runFromJson();
        } else {
            _runFromEnv();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JSON file mode  — multiple chains, multiple pools per chain
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reads the JSON config file and applies chain updates for every entry in remoteChains[].
    ///      All chain updates (removals + additions) are batched into a single applyChainUpdates call.
    function _runFromJson() internal {
        uint256 sourceChainId = block.chainid;
        string memory json = vm.readFile(JSON_INPUT_FILE);

        // Resolve source pool — JSON "sourcePool" field takes priority, then falls back to env vars.
        address poolAddress;
        if (vm.keyExistsJson(json, ".sourcePool") && bytes(vm.parseJsonString(json, ".sourcePool")).length > 0) {
            poolAddress = vm.parseJsonAddress(json, ".sourcePool");
        } else {
            poolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        }
        require(
            poolAddress != address(0),
            string.concat(
                "Token pool not deployed on source chain. Set 'sourcePool' in the JSON file, or set TOKEN_POOL / ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable."
            )
        );

        uint256 numChains = _jsonArrayLength(json, ".remoteChains");
        require(numChains > 0, "JSON file must contain at least one entry in 'remoteChains'.");

        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Apply Chain Updates (JSON mode)");
        console.log("========================================");
        console.log(string.concat("Source Chain:  ", helperConfig.getChainName(sourceChainId)));
        console.log(string.concat("Token Pool:    ", vm.toString(poolAddress)));
        console.log(string.concat("Input File:    ", JSON_INPUT_FILE));
        console.log(string.concat("Remote Chains: ", vm.toString(numChains)));
        console.log("========================================");
        console.log("");

        TokenPool poolContract = TokenPool(poolAddress);

        // Single pass: build all updates, detect which chains are already configured, and log.
        bool[] memory shouldRemove = new bool[](numChains);
        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](numChains);
        uint256 numRemovals = 0;

        for (uint256 i = 0; i < numChains; i++) {
            chainUpdates[i] = _buildChainUpdateFromJson(json, i);
            shouldRemove[i] = poolContract.isSupportedChain(chainUpdates[i].remoteChainSelector);
            if (shouldRemove[i]) {
                numRemovals++;
                console.log(
                    string.concat(
                        unicode"  ⚠️  [",
                        vm.toString(i),
                        "] Existing config for chain selector ",
                        vm.toString(chainUpdates[i].remoteChainSelector),
                        " will be replaced."
                    )
                );
            } else {
                console.log(
                    string.concat(
                        "  [",
                        vm.toString(i),
                        "] New chain selector ",
                        vm.toString(chainUpdates[i].remoteChainSelector),
                        " will be added."
                    )
                );
            }
        }

        uint64[] memory chainSelectorRemovals = new uint64[](numRemovals);
        uint256 removalIdx = 0;
        for (uint256 i = 0; i < numChains; i++) {
            if (shouldRemove[i]) chainSelectorRemovals[removalIdx++] = chainUpdates[i].remoteChainSelector;
        }

        console.log("");

        vm.startBroadcast();

        console.log(
            string.concat("[Step 1] Applying chain updates to pool on ", helperConfig.getChainName(sourceChainId))
        );
        poolContract.applyChainUpdates(chainSelectorRemovals, chainUpdates);
        console.log(unicode"✅ Chain updates applied successfully!");

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log(
            string.concat(unicode"✅ Chain Updates Complete on ", helperConfig.getChainName(sourceChainId), "!")
        );
        console.log("========================================");
        console.log(string.concat("Token Pool:               ", vm.toString(poolAddress)));
        console.log(string.concat("Remote chains configured: ", vm.toString(numChains)));
        console.log(
            string.concat(
                "Explorer:                 ", helperConfig.getExplorerUrl(sourceChainId, "/address/", poolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }

    /// @dev Holds chain metadata resolved from a JSON remoteChains[] entry.
    struct JsonChainMeta {
        uint64 chainSelector;
        string displayName;
        string destChainFamilyStr;
        ChainHandlers.ChainFamily destChainFamily;
    }

    /// @dev Holds encoded address arrays resolved from a JSON remoteChains[] entry.
    struct JsonChainAddrs {
        bytes tokenEncoded;
        bytes[] encodedPools;
        string rawTokenAddress;
        string[] rawPoolAddresses;
    }

    /// @dev Resolves chain selector and builds a ChainUpdate struct for remoteChains[index].
    ///      Split into sub-helpers to stay within the EVM's 16-slot stack limit.
    function _buildChainUpdateFromJson(string memory json, uint256 index)
        internal
        view
        returns (TokenPool.ChainUpdate memory update)
    {
        string memory prefix = string.concat(".remoteChains[", vm.toString(index), "]");

        JsonChainMeta memory meta = _resolveJsonChainMeta(json, prefix, index);

        JsonChainAddrs memory addrs =
            _resolveJsonAddresses(json, prefix, index, meta.destChainFamily, meta.destChainFamilyStr);

        RateLimiter.Config memory outbound = _parseRateLimitFromJson(json, string.concat(prefix, ".outboundRateLimit"));
        RateLimiter.Config memory inbound = _parseRateLimitFromJson(json, string.concat(prefix, ".inboundRateLimit"));

        _logJsonChainEntry(index, meta, addrs, outbound, inbound);

        update = TokenPool.ChainUpdate({
            remoteChainSelector: meta.chainSelector,
            remotePoolAddresses: addrs.encodedPools,
            remoteTokenAddress: addrs.tokenEncoded,
            outboundRateLimiterConfig: outbound,
            inboundRateLimiterConfig: inbound
        });
    }

    /// @dev Resolves chain selector, display name, and family for a remoteChains[index] entry.
    function _resolveJsonChainMeta(string memory json, string memory prefix, uint256 index)
        internal
        view
        returns (JsonChainMeta memory meta)
    {
        string memory destChainName = vm.parseJsonString(json, string.concat(prefix, ".destChain"));
        HelperConfig.NetworkConfig memory destConfig = helperConfig.getDestChainConfig(destChainName);

        if (vm.keyExistsJson(json, string.concat(prefix, ".destChainFamily"))) {
            meta.destChainFamilyStr = vm.parseJsonString(json, string.concat(prefix, ".destChainFamily"));
        } else {
            meta.destChainFamilyStr = bytes(destConfig.chainFamily).length > 0 ? destConfig.chainFamily : string("evm");
        }
        meta.destChainFamily = ChainHandlers.parseChainFamily(meta.destChainFamilyStr);

        if (vm.keyExistsJson(json, string.concat(prefix, ".destChainSelector"))) {
            meta.chainSelector = uint64(vm.parseJsonUint(json, string.concat(prefix, ".destChainSelector")));
        } else {
            meta.chainSelector = destConfig.chainSelector;
        }
        require(
            meta.chainSelector != 0,
            string.concat(
                "Chain selector is 0 for remoteChains[",
                vm.toString(index),
                "]. Set 'destChainSelector' in the JSON entry or use a recognized 'destChain' name."
            )
        );

        meta.displayName = bytes(destConfig.chainName).length > 0 ? destConfig.chainName : destChainName;
    }

    /// @dev Validates and encodes pool and token addresses for a remoteChains[index] entry.
    function _resolveJsonAddresses(
        string memory json,
        string memory prefix,
        uint256 index,
        ChainHandlers.ChainFamily destChainFamily,
        string memory destChainFamilyStr
    ) internal pure returns (JsonChainAddrs memory addrs) {
        addrs.rawTokenAddress = vm.parseJsonString(json, string.concat(prefix, ".destToken"));
        require(
            ChainHandlers.validateChainAddress(addrs.rawTokenAddress, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " token address: ", addrs.rawTokenAddress)
        );
        addrs.tokenEncoded = ChainHandlers.prepareChainAddressData(addrs.rawTokenAddress, destChainFamily);

        addrs.rawPoolAddresses = vm.parseJsonStringArray(json, string.concat(prefix, ".destPools"));
        require(
            addrs.rawPoolAddresses.length > 0,
            string.concat("remoteChains[", vm.toString(index), "].destPools must contain at least one address.")
        );

        addrs.encodedPools = new bytes[](addrs.rawPoolAddresses.length);
        for (uint256 p = 0; p < addrs.rawPoolAddresses.length; p++) {
            require(
                ChainHandlers.validateChainAddress(addrs.rawPoolAddresses[p], destChainFamily),
                string.concat("Invalid ", destChainFamilyStr, " pool address: ", addrs.rawPoolAddresses[p])
            );
            addrs.encodedPools[p] = ChainHandlers.prepareChainAddressData(addrs.rawPoolAddresses[p], destChainFamily);
        }
    }

    /// @dev Logs a summary of one remoteChains[index] entry.
    function _logJsonChainEntry(
        uint256 index,
        JsonChainMeta memory meta,
        JsonChainAddrs memory addrs,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) internal pure {
        console.log(string.concat("  [", vm.toString(index), "] ", meta.displayName));
        console.log(string.concat("      Selector:       ", vm.toString(meta.chainSelector)));
        console.log(string.concat("      Family:         ", meta.destChainFamilyStr));
        console.log(string.concat("      Token:          ", addrs.rawTokenAddress));
        console.log(string.concat("      Pools:          ", vm.toString(addrs.rawPoolAddresses.length)));
        for (uint256 p = 0; p < addrs.rawPoolAddresses.length; p++) {
            console.log(string.concat("        [", vm.toString(p), "] ", addrs.rawPoolAddresses[p]));
        }
        console.log(string.concat("      Outbound RL:    enabled=", vm.toString(outbound.isEnabled)));
        console.log(string.concat("      Inbound RL:     enabled=", vm.toString(inbound.isEnabled)));
    }

    /// @dev Parses an optional rate limit object from JSON. Returns a disabled config if the key is absent.
    function _parseRateLimitFromJson(string memory json, string memory key)
        internal
        view
        returns (RateLimiter.Config memory config)
    {
        if (!vm.keyExistsJson(json, key)) {
            return RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
        }
        bool enabled = vm.parseJsonBool(json, string.concat(key, ".enabled"));
        uint128 capacity = enabled ? uint128(vm.parseJsonUint(json, string.concat(key, ".capacity"))) : 0;
        uint128 rate = enabled ? uint128(vm.parseJsonUint(json, string.concat(key, ".rate"))) : 0;
        config = RateLimiter.Config({isEnabled: enabled, capacity: capacity, rate: rate});
    }

    /// @dev Returns the length of a JSON array at `arrayKey` by probing indices until one is missing.
    ///      forge-std does not expose a direct array-length function, so we probe until keyExistsJson returns false.
    function _jsonArrayLength(string memory json, string memory arrayKey) internal view returns (uint256 length) {
        while (vm.keyExistsJson(json, string.concat(arrayKey, "[", vm.toString(length), "]"))) {
            length++;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CLI / env var mode  — single destination chain (original behaviour)
    // ─────────────────────────────────────────────────────────────────────────

    function _runFromEnv() internal {
        // Get destination chain name from environment variable
        string memory destChainName = vm.envString("DEST_CHAIN");

        // Look up chain config by name — covers both EVM and non-EVM destinations.
        // DEST_CHAIN_FAMILY / DEST_CHAIN_SELECTOR env vars always take precedence.
        HelperConfig.NetworkConfig memory destConfig = helperConfig.getDestChainConfig(destChainName);
        string memory destChainFamilyStr = vm.envOr(
            "DEST_CHAIN_FAMILY", bytes(destConfig.chainFamily).length > 0 ? destConfig.chainFamily : string("evm")
        );
        ChainHandlers.ChainFamily destChainFamily = ChainHandlers.parseChainFamily(destChainFamilyStr);

        uint256 sourceChainId = block.chainid;

        bool isEvmDest = destChainFamily == ChainHandlers.ChainFamily.EVM;

        // Get deployed pool address from source chain (always EVM)
        address poolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        require(
            poolAddress != address(0),
            string.concat(
                "Token pool not deployed on source chain. Set TOKEN_POOL or ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable."
            )
        );

        // Resolve all destination chain parameters into a single struct to keep
        // the local-variable count in run() within the EVM's 16-slot stack limit.
        DestChainParams memory dest =
            _resolveDestChainParams(destChainName, destChainFamilyStr, destChainFamily, isEvmDest, destConfig);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Apply Chain Updates");
        console.log("========================================");
        console.log(string.concat("Chain:        ", helperConfig.getChainName(sourceChainId)));
        console.log(string.concat("Remote Chain: ", dest.displayName));
        console.log(string.concat("Token Pool:   ", vm.toString(poolAddress)));
        console.log(string.concat("Action:       ", "Configure cross-chain lane"));
        console.log("========================================");
        console.log("");

        (RateLimiter.Config memory outboundRateLimiterConfig, RateLimiter.Config memory inboundRateLimiterConfig) =
            _buildRateLimiterConfigs();

        console.log("Chain Update Parameters:");
        console.log(string.concat("  Source Pool:                  ", vm.toString(poolAddress)));
        console.log(string.concat("  Destination Chain Selector:   ", vm.toString(dest.chainSelector)));
        console.log(string.concat("  Destination Chain Family:     ", destChainFamilyStr));
        console.log(string.concat("  Destination Pool:             ", dest.rawPoolAddress));
        console.log(string.concat("  Destination Token:            ", dest.rawTokenAddress));
        console.log(string.concat("  Outbound Rate Limit Enabled:  ", vm.toString(outboundRateLimiterConfig.isEnabled)));
        console.log(
            string.concat("  Outbound Rate Limit Rate:     ", vm.toString(uint256(outboundRateLimiterConfig.rate)))
        );
        console.log(string.concat("  Inbound Rate Limit Enabled:   ", vm.toString(inboundRateLimiterConfig.isEnabled)));
        console.log(
            string.concat("  Inbound Rate Limit Capacity:  ", vm.toString(uint256(inboundRateLimiterConfig.capacity)))
        );
        console.log(
            string.concat("  Inbound Rate Limit Rate:      ", vm.toString(uint256(inboundRateLimiterConfig.rate)))
        );
        console.log("");

        vm.startBroadcast();

        console.log(
            string.concat("\n[Step 1] Applying chain updates to pool on ", helperConfig.getChainName(sourceChainId))
        );

        _applyChainUpdateToPool(poolAddress, dest, outboundRateLimiterConfig, inboundRateLimiterConfig);

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log(
            string.concat(unicode"✅ Chain Updates Complete on ", helperConfig.getChainName(sourceChainId), "!")
        );
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(poolAddress)));
        console.log(
            string.concat("Remote Chain: ", dest.displayName, " (Selector: ", vm.toString(dest.chainSelector), ")")
        );
        console.log(string.concat("Remote Pool:  ", dest.rawPoolAddress));
        console.log(
            string.concat("Explorer:     ", helperConfig.getExplorerUrl(sourceChainId, "/address/", poolAddress))
        );
        console.log("========================================");
        console.log("");
    }

    /// @dev Resolves all destination-chain parameters (selector, display name, validated
    ///      and encoded pool/token addresses) into a DestChainParams struct.
    ///      Extracted from _runFromEnv() to keep its stack depth within the EVM's 16-slot limit.
    function _resolveDestChainParams(
        string memory destChainName,
        string memory destChainFamilyStr,
        ChainHandlers.ChainFamily destChainFamily,
        bool isEvmDest,
        HelperConfig.NetworkConfig memory destConfig
    ) internal view returns (DestChainParams memory dest) {
        // Resolve destination chain selector from the config; DEST_CHAIN_SELECTOR always overrides.
        // Required for unknown chains (chainSelector == 0 in the zero config).
        uint64 chainSelector = uint64(vm.envOr("DEST_CHAIN_SELECTOR", uint256(destConfig.chainSelector)));
        require(chainSelector != 0, "Chain selector is not defined for the destination chain. Set DEST_CHAIN_SELECTOR.");
        dest.chainSelector = chainSelector;

        // Resolve human-readable destination chain name for logs.
        dest.displayName = bytes(destConfig.chainName).length > 0 ? destConfig.chainName : destChainName;

        // Resolve destination pool and token address strings.
        // For EVM: fall back to HelperConfig address lookup; convert address → string for uniform handling.
        // For non-EVM: DEST_TOKEN_POOL / DEST_TOKEN must be set explicitly.
        if (isEvmDest) {
            // CLI override (DEST_TOKEN_POOL) takes priority over the chain-specific env var.
            address destPoolAddr = vm.envOr(
                "DEST_TOKEN_POOL",
                helperConfig.getDeployedTokenPool(helperConfig.parseChainName(destConfig.chainNameIdentifier))
            );
            require(
                destPoolAddr != address(0),
                string.concat(
                    "Token pool not deployed on destination chain. Set DEST_TOKEN_POOL or ",
                    destChainName,
                    "_TOKEN_POOL environment variable."
                )
            );
            address destTokenAddr = vm.envOr(
                "DEST_TOKEN", helperConfig.getDeployedToken(helperConfig.parseChainName(destConfig.chainNameIdentifier))
            );
            require(
                destTokenAddr != address(0),
                string.concat(
                    "Token not deployed on destination chain. Set DEST_TOKEN or ",
                    destChainName,
                    "_TOKEN environment variable."
                )
            );
            dest.rawPoolAddress = vm.toString(destPoolAddr);
            dest.rawTokenAddress = vm.toString(destTokenAddr);
        } else {
            // DEST_TOKEN_POOL takes priority; fall back to <DEST_CHAIN>_TOKEN_POOL (e.g. SOLANA_DEVNET_TOKEN_POOL).
            string memory chainSpecificPool = vm.envOr(string.concat(destChainName, "_TOKEN_POOL"), string(""));
            dest.rawPoolAddress = vm.envOr("DEST_TOKEN_POOL", chainSpecificPool);
            require(
                bytes(dest.rawPoolAddress).length > 0,
                string.concat("Destination pool not set. Set DEST_TOKEN_POOL or ", destChainName, "_TOKEN_POOL.")
            );

            // DEST_TOKEN takes priority; fall back to <DEST_CHAIN>_TOKEN (e.g. SOLANA_DEVNET_TOKEN).
            string memory chainSpecificToken = vm.envOr(string.concat(destChainName, "_TOKEN"), string(""));
            dest.rawTokenAddress = vm.envOr("DEST_TOKEN", chainSpecificToken);
            require(
                bytes(dest.rawTokenAddress).length > 0,
                string.concat("Destination token not set. Set DEST_TOKEN or ", destChainName, "_TOKEN.")
            );
        }

        // Validate addresses for their destination chain family.
        require(
            ChainHandlers.validateChainAddress(dest.rawPoolAddress, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " pool address: ", dest.rawPoolAddress)
        );
        require(
            ChainHandlers.validateChainAddress(dest.rawTokenAddress, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " token address: ", dest.rawTokenAddress)
        );

        // Encode addresses for the destination chain family.
        // EVM:   abi.encode(address)  — 32-byte ABI-padded word
        // SVM:   raw 32 bytes          — base58-decoded Solana public key
        dest.poolEncoded = ChainHandlers.prepareChainAddressData(dest.rawPoolAddress, destChainFamily);
        dest.tokenEncoded = ChainHandlers.prepareChainAddressData(dest.rawTokenAddress, destChainFamily);
    }

    /// @dev Builds the ChainUpdate payload and calls applyChainUpdates on the pool.
    ///      Extracted from _runFromEnv() to keep its stack depth within the EVM's 16-slot limit.
    function _applyChainUpdateToPool(
        address poolAddress,
        DestChainParams memory dest,
        RateLimiter.Config memory outboundRateLimiterConfig,
        RateLimiter.Config memory inboundRateLimiterConfig
    ) internal {
        // Instantiate the source TokenPool contract
        TokenPool poolContract = TokenPool(poolAddress);

        // Pool address encoded per destination chain family
        bytes[] memory destPoolAddressesEncoded = new bytes[](1);
        destPoolAddressesEncoded[0] = dest.poolEncoded;

        // Idempotent: remove existing config for dest chain before applying new one
        bool chainAlreadyConfigured = poolContract.isSupportedChain(dest.chainSelector);
        uint64[] memory chainSelectorRemovals = chainAlreadyConfigured ? new uint64[](1) : new uint64[](0);
        if (chainAlreadyConfigured) {
            chainSelectorRemovals[0] = dest.chainSelector;
            console.log(unicode"⚠️  Existing config detected for destination chain selector; replacing it.");
        } else {
            console.log("No existing config for destination chain selector; adding new one.");
        }

        // Prepare chain update data
        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](1);
        chainUpdates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: dest.chainSelector,
            remotePoolAddresses: destPoolAddressesEncoded,
            remoteTokenAddress: dest.tokenEncoded,
            outboundRateLimiterConfig: outboundRateLimiterConfig,
            inboundRateLimiterConfig: inboundRateLimiterConfig
        });

        // Apply the chain updates
        poolContract.applyChainUpdates(chainSelectorRemovals, chainUpdates);
        console.log(unicode"✅ Chain updates applied successfully!");
    }

    /// @dev Reads optional rate limit env vars and returns outbound/inbound RateLimiter.Config structs.
    /// isEnabled defaults to true when CAPACITY or RATE are provided; override with ENABLED=false.
    function _buildRateLimiterConfigs()
        internal
        view
        returns (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound)
    {
        string memory sentinel = "__not_set__";
        bool outboundProvided = keccak256(bytes(vm.envOr("OUTBOUND_RATE_LIMIT_CAPACITY", sentinel)))
                != keccak256(bytes(sentinel))
            || keccak256(bytes(vm.envOr("OUTBOUND_RATE_LIMIT_RATE", sentinel))) != keccak256(bytes(sentinel));
        bool inboundProvided = keccak256(bytes(vm.envOr("INBOUND_RATE_LIMIT_CAPACITY", sentinel)))
                != keccak256(bytes(sentinel))
            || keccak256(bytes(vm.envOr("INBOUND_RATE_LIMIT_RATE", sentinel))) != keccak256(bytes(sentinel));

        bool outboundEnabled = vm.envOr("OUTBOUND_RATE_LIMIT_ENABLED", outboundProvided);
        bool inboundEnabled = vm.envOr("INBOUND_RATE_LIMIT_ENABLED", inboundProvided);

        outbound = RateLimiter.Config({
            isEnabled: outboundEnabled,
            capacity: outboundEnabled ? uint128(vm.envOr("OUTBOUND_RATE_LIMIT_CAPACITY", uint256(0))) : 0,
            rate: outboundEnabled ? uint128(vm.envOr("OUTBOUND_RATE_LIMIT_RATE", uint256(0))) : 0
        });
        inbound = RateLimiter.Config({
            isEnabled: inboundEnabled,
            capacity: inboundEnabled ? uint128(vm.envOr("INBOUND_RATE_LIMIT_CAPACITY", uint256(0))) : 0,
            rate: inboundEnabled ? uint128(vm.envOr("INBOUND_RATE_LIMIT_RATE", uint256(0))) : 0
        });
    }
}
