// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        uint64 chainSelector;
        address router;
        address rmnProxy;
        address tokenAdminRegistry;
        address registryModuleOwnerCustom;
        address link;
        address ccipBnM;
        uint256 confirmations;
        string chainName;
        string chainNameIdentifier;
        string explorerUrl;
        string nativeCurrencySymbol;
        string chainFamily;
    }

    // Chain IDs
    uint256 public constant ETHEREUM_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant ZERO_G_TESTNET_CHAIN_ID = 16602;
    uint256 public constant PLUME_TESTNET_CHAIN_ID = 98867;
    uint256 public constant INK_SEPOLIA_CHAIN_ID = 763373;
    uint256 public constant MANTLE_SEPOLIA_CHAIN_ID = 5003;

    // Deployed contract addresses
    mapping(uint256 => address) public deployedTokens;
    mapping(uint256 => address) public deployedTokenPools;

    constructor() {
        // Initialize deployed contracts from environment variables
        _initializeDeployedContracts(ETHEREUM_SEPOLIA_CHAIN_ID);
        _initializeDeployedContracts(ZERO_G_TESTNET_CHAIN_ID);
        _initializeDeployedContracts(PLUME_TESTNET_CHAIN_ID);
        _initializeDeployedContracts(INK_SEPOLIA_CHAIN_ID);
        _initializeDeployedContracts(MANTLE_SEPOLIA_CHAIN_ID);
    }

    /// @dev Helper to initialize deployed contract addresses from environment variables.
    ///
    /// Resolution order (highest priority first):
    ///   1. Inline short alias — `TOKEN` / `TOKEN_POOL`
    ///      Pass directly on the command line without exporting:
    ///      `TOKEN=0x... TOKEN_POOL=0x... forge script ...`
    ///   2. Chain-specific var — `{CHAIN}_TOKEN` / `{CHAIN}_TOKEN_POOL`
    ///      Set once per session: `export ETHEREUM_SEPOLIA_TOKEN=0x...`
    function _initializeDeployedContracts(uint256 chainId) private {
        string memory chainNameId = getNetworkConfig(chainId).chainNameIdentifier;

        // Initialize TOKEN contract — inline TOKEN alias takes priority
        address tokenFromAlias = vm.envOr("TOKEN", address(0));
        if (tokenFromAlias != address(0)) {
            deployedTokens[chainId] = tokenFromAlias;
        } else {
            deployedTokens[chainId] = vm.envOr(string.concat(chainNameId, "_TOKEN"), address(0));
        }

        // Initialize TOKEN_POOL contract — inline TOKEN_POOL alias takes priority
        address tokenPoolFromAlias = vm.envOr("TOKEN_POOL", address(0));
        if (tokenPoolFromAlias != address(0)) {
            deployedTokenPools[chainId] = tokenPoolFromAlias;
        } else {
            deployedTokenPools[chainId] = vm.envOr(string.concat(chainNameId, "_TOKEN_POOL"), address(0));
        }
    }

    function getEthereumSepoliaConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory ethereumSepoliaConfig = NetworkConfig({
            chainSelector: 16015286601757825753,
            router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
            rmnProxy: 0xba3f6251de62dED61Ff98590cB2fDf6871FbB991,
            tokenAdminRegistry: 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82,
            registryModuleOwnerCustom: 0xa3c796d480638d7476792230da1E2ADa86e031b0,
            link: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            ccipBnM: 0x9a97F119cFE1D5Ea77c264441C0A0aBC9B34E119,
            confirmations: 2,
            chainName: "Ethereum Sepolia",
            chainNameIdentifier: "ETHEREUM_SEPOLIA",
            explorerUrl: "https://sepolia.etherscan.io",
            nativeCurrencySymbol: "ETH",
            chainFamily: "evm"
        });
        return ethereumSepoliaConfig;
    }

    function getZeroGTestnetConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory zeroGTestnetConfig = NetworkConfig({
            chainSelector: 6892437333620424805,
            router: 0xD610B8f58689de7755947C05342A2DFaC30ebD57,
            rmnProxy: 0x995ab3eC29E1660A93cFddAA19C710A1b5afCCc9,
            tokenAdminRegistry: 0x23a5084Fa78104F3DF11C63Ae59fcac4f6AD9DeE,
            registryModuleOwnerCustom: 0x0820f975ce90EE5c508657F0C58b71D1fcc85cE0,
            link: 0xe5e3a4fF1773d043a387b16Ceb3c91cC49bAFD54,
            ccipBnM: 0xDbB255D37BC7c9e2b08e5a1C9f9506c9E85F1644,
            confirmations: 2,
            chainName: "0g Galileo Testnet",
            chainNameIdentifier: "0G_GALILEO_TESTNET",
            explorerUrl: "https://chainscan-galileo.0g",
            nativeCurrencySymbol: "OG",
            chainFamily: "evm"
        });
        return zeroGTestnetConfig;
    }

    function getPlumeTestnetConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory plumeTestnetConfig = NetworkConfig({
            chainSelector: 13874588925447303949,
            router: 0x5e5Fd4720E1CE826138D043aF578D69f48af502F,
            rmnProxy: 0xAa3ae5481EE445711252131f1516922D0962916A,
            tokenAdminRegistry: 0x855cF0d18A0BeBEDA7c1CD2F943686120cCCC6bd,
            registryModuleOwnerCustom: 0x693926456C8b210f56E29Bc5b4514B32A5224c88,
            link: 0xB97e3665AEAF96BDD6b300B2e0C93C662104A068,
            ccipBnM: 0x225fAc4130595d1C7dabbE61A8bA9B051440b76c,
            confirmations: 2,
            chainName: "Plume Testnet",
            chainNameIdentifier: "PLUME_TESTNET",
            explorerUrl: "https://testnet-explorer.plume.org",
            nativeCurrencySymbol: "PLUME",
            chainFamily: "evm"
        });
        return plumeTestnetConfig;
    }

    function getInkSepoliaConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory inkSepoliaConfig = NetworkConfig({
            chainSelector: 9763904284804119144,
            router: 0x17fCda531D8E43B4e2a2A2492FBcd4507a1685A1,
            rmnProxy: 0x84017cfddD12D319E5bBf090e0de6d55B78160Cb,
            tokenAdminRegistry: 0x3A849a05a590FeaEf26c2d425241A2BF29307161,
            registryModuleOwnerCustom: 0xaB018890bBdDf9B80E21d1c335c5f6acdbE0f5D6,
            link: 0x3423C922911956b1Ccbc2b5d4f38216a6f4299b4,
            ccipBnM: 0x414dbe1d58dd9BA7C84f7Fc0e4f82bc858675d37,
            confirmations: 2,
            chainName: "Ink Sepolia",
            chainNameIdentifier: "INK_SEPOLIA",
            explorerUrl: "https://explorer-sepolia.inkonchain.com",
            nativeCurrencySymbol: "INK",
            chainFamily: "evm"
        });
        return inkSepoliaConfig;
    }

    function getMantleSepoliaConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory mantleSepoliaConfig = NetworkConfig({
            chainSelector: 8236463271206331221,
            router: 0xFd33fd627017fEf041445FC19a2B6521C9778f86,
            rmnProxy: 0xcCB84Ec3F6AFdD2052134f74aaAc95Ae41A7B333,
            tokenAdminRegistry: 0x0F1eE88A582f31d92510E300fc1330AA5a525D51,
            registryModuleOwnerCustom: 0xf76cE612250eeEb8889F49FBCB11f1c2705305F6,
            link: 0x22bdEdEa0beBdD7CfFC95bA53826E55afFE9DE04,
            ccipBnM: 0xBB370F829bdB6fC44f3D34e2A2107578bB2c3F0B,
            confirmations: 2,
            chainName: "Mantle Sepolia",
            chainNameIdentifier: "MANTLE_SEPOLIA",
            explorerUrl: "https://sepolia.mantlescan.xyz",
            nativeCurrencySymbol: "MNT",
            chainFamily: "evm"
        });
        return mantleSepoliaConfig;
    }

    // ── Non-EVM destination chains ──────────────────────────────────────────────────────────────
    // Non-EVM chains are only supported as the **destination** chain when calling ApplyChainUpdates
    // — i.e. to register a non-EVM token pool on an EVM source chain. They cannot be used as
    // source chains in this repo.
    // That's why fields like router, rmnProxy, tokenAdminRegistry, etc. are not applicable
    // and are intentionally left as zero/empty.
    // Add more entries here as new non-EVM lanes go live.

    /// @notice Returns the network configuration for Solana Devnet.
    /// @dev Only chainSelector, chainName, chainNameIdentifier, nativeCurrencySymbol, and chainFamily are used.
    function getSolanaDevnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            chainSelector: 16423721717087811551,
            router: address(0), // NOT REQUIRED — non-EVM chain
            rmnProxy: address(0), // NOT REQUIRED — non-EVM chain
            tokenAdminRegistry: address(0), // NOT REQUIRED — non-EVM chain
            registryModuleOwnerCustom: address(0), // NOT REQUIRED — non-EVM chain
            link: address(0), // NOT REQUIRED — non-EVM chain
            ccipBnM: address(0), // NOT REQUIRED — non-EVM chain
            confirmations: 0, // NOT REQUIRED — non-EVM chain
            chainName: "Solana Devnet",
            chainNameIdentifier: "SOLANA_DEVNET",
            explorerUrl: "", // NOT REQUIRED — non-EVM chain
            nativeCurrencySymbol: "SOL",
            chainFamily: "svm"
        });
    }

    /// @notice Resolves a chain name (e.g. "SOLANA_DEVNET", "AVALANCHE_FUJI") to its NetworkConfig.
    /// @dev Handles both EVM and non-EVM chains. Returns a zero config (chainFamily = "") for
    ///      unrecognized names so callers can fall back to DEST_CHAIN_FAMILY / DEST_CHAIN_SELECTOR.
    function getDestChainConfig(string memory chainName) public pure returns (NetworkConfig memory) {
        bytes32 h = keccak256(abi.encodePacked(chainName));
        if (h == keccak256(abi.encodePacked("ETHEREUM_SEPOLIA"))) return getEthereumSepoliaConfig();
        if (h == keccak256(abi.encodePacked("ZERO_G_TESTNET"))) return getZeroGTestnetConfig();
        if (h == keccak256(abi.encodePacked("PLUME_TESTNET"))) return getPlumeTestnetConfig();
        if (h == keccak256(abi.encodePacked("INK_SEPOLIA"))) return getInkSepoliaConfig();
        if (h == keccak256(abi.encodePacked("MANTLE_SEPOLIA"))) return getMantleSepoliaConfig();
        if (h == keccak256(abi.encodePacked("SOLANA_DEVNET"))) return getSolanaDevnetConfig();
        NetworkConfig memory unknown;
        return unknown;
    }

    function getNetworkConfig(uint256 chainId) public pure returns (NetworkConfig memory) {
        if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) {
            return getEthereumSepoliaConfig();
        } else if (chainId == ZERO_G_TESTNET_CHAIN_ID) {
            return getZeroGTestnetConfig();
        } else if (chainId == PLUME_TESTNET_CHAIN_ID) {
            return getPlumeTestnetConfig();
        } else if (chainId == INK_SEPOLIA_CHAIN_ID) {
            return getInkSepoliaConfig();
        } else if (chainId == MANTLE_SEPOLIA_CHAIN_ID) {
            return getMantleSepoliaConfig();
        } else {
            revert("Unsupported chain ID");
        }
    }

    function getDeployedToken(uint256 chainId) public view returns (address) {
        return deployedTokens[chainId];
    }

    function getDeployedTokenPool(uint256 chainId) public view returns (address) {
        return deployedTokenPools[chainId];
    }

    /// @dev Converts a chain name identifier (e.g. "AVALANCHE_FUJI") to its EVM chain ID.
    ///      EVM chains only — non-EVM chains (e.g. "SOLANA_DEVNET") have no EVM chain ID
    ///      and will revert with "Invalid chain name".
    function parseChainName(string memory chainName) public pure returns (uint256) {
        bytes32 nameHash = keccak256(abi.encodePacked(chainName));

        if (nameHash == keccak256(abi.encodePacked(getEthereumSepoliaConfig().chainNameIdentifier))) {
            return ETHEREUM_SEPOLIA_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getZeroGTestnetConfig().chainNameIdentifier))) {
            return ZERO_G_TESTNET_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getPlumeTestnetConfig().chainNameIdentifier))) {
            return PLUME_TESTNET_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getInkSepoliaConfig().chainNameIdentifier))) {
            return INK_SEPOLIA_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getMantleSepoliaConfig().chainNameIdentifier))) {
            return MANTLE_SEPOLIA_CHAIN_ID;
        }

        revert("Invalid chain name");
    }

    function getChainName(uint256 chainId) public pure returns (string memory) {
        return getNetworkConfig(chainId).chainName;
    }

    function getChainNameBySelector(uint64 chainSelector) public pure returns (string memory) {
        if (chainSelector == getEthereumSepoliaConfig().chainSelector) return getEthereumSepoliaConfig().chainName;
        if (chainSelector == getZeroGTestnetConfig().chainSelector) return getZeroGTestnetConfig().chainName;
        if (chainSelector == getPlumeTestnetConfig().chainSelector) return getPlumeTestnetConfig().chainName;
        if (chainSelector == getInkSepoliaConfig().chainSelector) return getInkSepoliaConfig().chainName;
        if (chainSelector == getMantleSepoliaConfig().chainSelector) return getMantleSepoliaConfig().chainName;
        if (chainSelector == getSolanaDevnetConfig().chainSelector) return getSolanaDevnetConfig().chainName;
        return "Unknown";
    }

    function getNativeCurrencySymbol(uint256 chainId) public pure returns (string memory) {
        return getNetworkConfig(chainId).nativeCurrencySymbol;
    }

    function getExplorerUrl(uint256 chainId, string memory pathType, address contractAddress)
        public
        pure
        returns (string memory)
    {
        return string.concat(getNetworkConfig(chainId).explorerUrl, pathType, vm.toString(contractAddress));
    }
}
